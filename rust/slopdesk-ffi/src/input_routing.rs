//! The raise decision for one input event — `Sources/SlopDeskVideoHost/VideoSessionLogic.swift`.
//!
//! Raising is the expensive half of injecting: the chain is six to ten SYNCHRONOUS cross-process
//! accessibility calls, each capped at the messaging timeout, and the input consumer AWAITS all of
//! them before the click is posted. So the question "does this event need it" is the dominant felt
//! input latency in the whole system, and it is decided here rather than at four call sites.
//!
//! ## One door, four answers
//!
//! The four predicates are one reading of one event — whether it always raises, whether it re-arms
//! the latch for the next one, whether it is exempt from an armed latch, and the raise itself — so
//! they cross as bits of one flag word rather than as four calls that could disagree about which
//! event they were asked about.
//!
//! An event no arm answers to reads as RAISE: erring toward raising costs latency and never
//! weakens the activate-then-control discipline, while erring the other way posts a click into a
//! window that was never focused.

use slopdesk_video::geometry::VideoPoint;
use slopdesk_video::input_event::{InputEvent, MouseButton, ScrollEvent};
use slopdesk_video::input_routing::{
    InputButtonBalance, ScrollAccumulator, ScrollCoalescePlanner, always_raises, latch_exempt_from_raise,
    raise_first, rearm_raise_after, should_raise,
};

use crate::input_event::{SlopDeskInputEvent, flatten, rebuild};
use crate::records_of;

/// This event must be raised and focused before it is posted, given the latch.
pub const INPUT_RAISE_FIRST: u32 = 1;
/// This event ALWAYS raises, latch or not — a pointer button-down.
pub const INPUT_RAISE_ALWAYS: u32 = 2;
/// After this event, the NEXT one must raise — a mouse-up ends an interaction.
pub const INPUT_RAISE_REARM: u32 = 4;
/// This event is exempt from an armed latch — a scroll goes to the window under the cursor.
pub const INPUT_RAISE_LATCH_EXEMPT: u32 = 8;

/// The whole raise reading of one event, as `INPUT_RAISE_*` bits.
///
/// `needs_raise` is the caller's latch: true on the first event, and re-armed after a mouse-up so a
/// fresh click sequence re-raises. Only `INPUT_RAISE_FIRST` depends on it; the other three are
/// properties of the event alone, which is why one call answers a caller that asks at two different
/// moments.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub extern "C" fn slopdesk_input_raise_flags(event: SlopDeskInputEvent, needs_raise: bool) -> u32 {
    // The text an event carries cannot change whether it raises, so the empty payload is enough to
    // read the arm — and a record no arm answers to raises, re-arms, and is not exempt.
    let Some(event) = rebuild(event, &[]) else {
        return INPUT_RAISE_FIRST | INPUT_RAISE_ALWAYS | INPUT_RAISE_REARM;
    };
    let mut flags = 0;
    if raise_first(&event, needs_raise) {
        flags |= INPUT_RAISE_FIRST;
    }
    if always_raises(&event) {
        flags |= INPUT_RAISE_ALWAYS;
    }
    if rearm_raise_after(&event) {
        flags |= INPUT_RAISE_REARM;
    }
    if latch_exempt_from_raise(&event) {
        flags |= INPUT_RAISE_LATCH_EXEMPT;
    }
    flags
}

/// Whether to run the full accessibility raise chain at all, from a CHEAP frontmost-app read.
///
/// An absent frontmost crosses as `has_frontmost == false` rather than a sentinel pid, and reads as
/// RAISE — an unknown frontmost is exactly the uncertainty this errs toward raising on.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub const extern "C" fn slopdesk_input_should_raise(
    has_frontmost: bool,
    frontmost_pid: i32,
    target_pid: i32,
    first_interaction: bool,
) -> bool {
    let frontmost = if has_frontmost { Some(frontmost_pid) } else { None };
    should_raise(frontmost, target_pid, first_interaction)
}

/// The button and modifier ledger, as the twelve bits it really is.
///
/// Both domains are fixed — three buttons the wire admits, nine modifier keycodes — so the whole
/// ledger crosses BY VALUE, which is what a caller holding it in a `struct` needs (`docs/55` §4b):
/// a handle it copied would be two ledgers by the second copy. The modifier bit is the key's
/// position in the crate's held-modifier table.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SlopDeskInputBalance {
    /// One bit per held modifier key.
    pub modifiers: u16,
    /// One bit per held mouse button.
    pub buttons: u8,
}

/// What to do before injecting one event, and the ledger it leaves behind.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SlopDeskInjectionPlan {
    /// The ledger AFTER the fold — the caller stores this back.
    pub state: SlopDeskInputBalance,
    /// The button to release synthetically first, meaningful only when `has_pre_release`.
    pub pre_release: u8,
    /// Whether a synthetic release must be posted before the real event.
    pub has_pre_release: bool,
    /// Whether the event must NOT be posted at all.
    pub suppress: bool,
}

/// Folds one event into the ledger and answers its injection plan plus the new ledger.
///
/// A down for an already-held button asks for a pre-release and then stays held, because the fresh
/// down owns it; an up for a held button releases it and posts; an up for a button that is not held
/// is the client's loss-resilient duplicate and is SUPPRESSED, which is what makes the wire's
/// redundancy idempotent at the host. Modifier key edges get the same treatment, and ordinary keys
/// and the caps-lock toggle pass through.
///
/// A record no arm answers to passes through untouched, ledger and all — it cannot be a down or an
/// up, so there is nothing to fold and nothing to suppress.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub extern "C" fn slopdesk_input_balance_plan(
    state: SlopDeskInputBalance,
    event: SlopDeskInputEvent,
) -> SlopDeskInjectionPlan {
    let mut balance = InputButtonBalance::from_masks(state.buttons, state.modifiers);
    // The text an event carries cannot move the ledger, so the empty payload is enough to read the
    // arm — a key or a button never had any.
    let Some(event) = rebuild(event, &[]) else {
        return SlopDeskInjectionPlan {
            state,
            ..SlopDeskInjectionPlan::default()
        };
    };
    let plan = balance.plan(&event);
    let (buttons, modifiers) = balance.masks();
    SlopDeskInjectionPlan {
        state: SlopDeskInputBalance { modifiers, buttons },
        pre_release: plan.pre_release.map_or(0, MouseButton::raw_value),
        has_pre_release: plan.pre_release.is_some(),
        suppress: plan.suppress,
    }
}

/// The time-gated scroll accumulator, as the scalars it is made of.
///
/// Held ACROSS drains, so it crosses BY VALUE for the same reason the ledger does: its owner is a
/// `struct` field that gets copied, and a handle it copied would be two accumulators. Everything in
/// it is a number — the summed travel, when the last emit went out, and the template the summed
/// emit is stamped with — because a summed scroll is the planner's OWN event and a scroll carries
/// nothing that needs a heap.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct SlopDeskScrollPlanner {
    /// The summed horizontal travel.
    pub accumulated_dx: f64,
    /// The summed vertical travel.
    pub accumulated_dy: f64,
    /// The template's normalised x.
    pub template_x: f64,
    /// The template's normalised y.
    pub template_y: f64,
    /// When the last emit went out, on the caller's clock.
    pub last_inject_at: f64,
    /// The minimum spacing between emits.
    pub inject_interval: f64,
    /// The template's self-inject filter tag.
    pub template_tag: u32,
    /// The template's gesture phase.
    pub template_scroll_phase: u8,
    /// The template's momentum phase.
    pub template_momentum_phase: u8,
    /// Whether the template's deltas are pixel-precise.
    pub template_continuous: bool,
    /// Whether anything is accumulated at all.
    pub has_template: bool,
    /// Whether scroll coalescing is armed.
    pub coalesce_scroll: bool,
}

/// One event the planner wants injected, and where it came from.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct SlopDeskPlannedEvent {
    /// The event, flat. For a passed-through event this is a copy of the caller's own record, whose
    /// text (if any) the caller still holds — which is why `source` is the field to read.
    pub event: SlopDeskInputEvent,
    /// The index in the run this event IS, meaningful only when `has_source`.
    pub source: u32,
    /// Whether this event is one of the caller's, rather than the planner's own summed emit.
    pub has_source: bool,
}

/// A planner with nothing accumulated.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub const extern "C" fn slopdesk_scroll_planner_new(
    inject_interval: f64,
    coalesce_scroll: bool,
) -> SlopDeskScrollPlanner {
    SlopDeskScrollPlanner {
        accumulated_dx: 0.0,
        accumulated_dy: 0.0,
        template_x: 0.0,
        template_y: 0.0,
        last_inject_at: 0.0,
        inject_interval,
        template_tag: 0,
        template_scroll_phase: 0,
        template_momentum_phase: 0,
        template_continuous: false,
        has_template: false,
        coalesce_scroll,
    }
}

/// Drops any pending residual WITHOUT emitting it — a media teardown, where a stale gesture tail
/// must not leak into the next session.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub extern "C" fn slopdesk_scroll_planner_clear(state: SlopDeskScrollPlanner) -> SlopDeskScrollPlanner {
    // Through the planner rather than by zeroing the record here: WHICH fields a teardown drops —
    // the sums and the template, but not when the last emit went out — is the fold's rule, and a
    // second spelling of it would be a gate that re-armed itself on a reconnect.
    let mut planner = planner_of(state);
    planner.clear_pending();
    crossing(&planner, state)
}

/// Folds one arrival-ordered run and answers the events to inject NOW, in order.
///
/// There is deliberately no early return for an empty run: a drain that carried only control or
/// recovery datagrams must still reach the trailing flush, or a residual stranded by a LOST
/// gesture-end datagram waits for the next unrelated input event.
///
/// The state is only COMMITTED when the answer fits: a caller that lent too little gets the count
/// it should have lent and a planner that has not moved, so the retry folds the run once rather
/// than twice. Lend `2 * count + 2` and it always fits on the first call.
///
/// # Safety
/// `state` must point to one writable, aligned planner, `events` must be null or point to `count`
/// readable records, and `out` must be null or point to `cap` writable slots, all for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_scroll_planner_plan(
    state: *mut SlopDeskScrollPlanner,
    events: *const SlopDeskInputEvent,
    count: usize,
    now: f64,
    out: *mut SlopDeskPlannedEvent,
    cap: usize,
) -> usize {
    if state.is_null() {
        return 0;
    }
    // SAFETY: non-null and, by the caller's obligation, one readable, aligned planner.
    let held = unsafe { *state };
    // SAFETY: the caller's obligation, discharged by Swift's `withUnsafeBufferPointer`.
    let records = unsafe { records_of(events, count) };
    // The text a record points at cannot move the accumulator — a text event is a barrier whatever
    // it says — so the empty payload is enough, and the caller keeps its strings.
    let run: Vec<_> = records
        .iter()
        .map(|record| rebuild(*record, &[]).unwrap_or_else(|| InputEvent::Text(String::new(), 0)))
        .collect();
    let mut folded = planner_of(held);
    let answer = folded.plan_slots(&run, now);
    if out.is_null() || answer.len() > cap {
        return answer.len(); // nothing written, and the planner has NOT moved
    }
    let planned: Vec<SlopDeskPlannedEvent> = answer
        .iter()
        .map(|slot| {
            SlopDeskPlannedEvent {
                event: flatten(&slot.event),
                source: slot
                    .source
                    .map_or(0, |source| u32::try_from(source).unwrap_or(u32::MAX)),
                has_source: slot.source.is_some(),
            }
        })
        .collect();
    // SAFETY: `planned.len() <= cap` was just checked, `out` is non-null and writable for `cap`
    // slots by the caller's obligation, and `planned` was allocated inside this call.
    unsafe { core::ptr::copy_nonoverlapping(planned.as_ptr(), out, planned.len()) };
    // SAFETY: non-null and, by the caller's obligation, one writable, aligned planner.
    unsafe { *state = crossing(&folded, held) };
    planned.len()
}

/// The planner rebuilt from the scalars it crossed as.
fn planner_of(state: SlopDeskScrollPlanner) -> ScrollCoalescePlanner {
    ScrollCoalescePlanner::restored(state.inject_interval, state.coalesce_scroll, ScrollAccumulator {
        dx: state.accumulated_dx,
        dy: state.accumulated_dy,
        template: state.has_template.then(|| {
            (
                ScrollEvent {
                    dx: 0.0,
                    dy: 0.0,
                    normalized: VideoPoint::new(state.template_x, state.template_y),
                    scroll_phase: state.template_scroll_phase,
                    momentum_phase: state.template_momentum_phase,
                    continuous: state.template_continuous,
                },
                state.template_tag,
            )
        }),
        last_inject_at: state.last_inject_at,
    })
}

/// The planner back as scalars, keeping the settings the fold never touches.
fn crossing(planner: &ScrollCoalescePlanner, held: SlopDeskScrollPlanner) -> SlopDeskScrollPlanner {
    let accumulator = planner.accumulator();
    let template = accumulator.template;
    SlopDeskScrollPlanner {
        accumulated_dx: accumulator.dx,
        accumulated_dy: accumulator.dy,
        template_x: template.map_or(0.0, |(scroll, _)| scroll.normalized.x),
        template_y: template.map_or(0.0, |(scroll, _)| scroll.normalized.y),
        last_inject_at: accumulator.last_inject_at,
        template_tag: template.map_or(0, |(_, tag)| tag),
        template_scroll_phase: template.map_or(0, |(scroll, _)| scroll.scroll_phase),
        template_momentum_phase: template.map_or(0, |(scroll, _)| scroll.momentum_phase),
        template_continuous: template.is_some_and(|(scroll, _)| scroll.continuous),
        has_template: template.is_some(),
        ..held
    }
}

#[cfg(test)]
#[expect(
    unsafe_code,
    clippy::indexing_slicing,
    clippy::float_cmp,
    reason = "the tests call the C entry points, and these sums are exact by the law under test"
)]
mod tests {
    use super::{
        INPUT_RAISE_ALWAYS, INPUT_RAISE_FIRST, INPUT_RAISE_LATCH_EXEMPT, INPUT_RAISE_REARM,
        SlopDeskInputBalance, SlopDeskPlannedEvent, SlopDeskScrollPlanner, slopdesk_input_balance_plan,
        slopdesk_input_raise_flags, slopdesk_input_should_raise, slopdesk_scroll_planner_clear,
        slopdesk_scroll_planner_new, slopdesk_scroll_planner_plan,
    };
    use crate::input_event::SlopDeskInputEvent;

    fn scroll(dy: f64) -> SlopDeskInputEvent {
        SlopDeskInputEvent {
            dy,
            message_type: 4,
            scroll_phase: 2,
            ..SlopDeskInputEvent::default()
        }
    }

    /// One run through the planner door, lent the `2 * count + 2` slots that always fit.
    fn plan_run(
        state: &mut SlopDeskScrollPlanner,
        run: &[SlopDeskInputEvent],
        now: f64,
    ) -> Vec<SlopDeskPlannedEvent> {
        let mut out = vec![SlopDeskPlannedEvent::default(); run.len() * 2 + 2];
        let written = unsafe {
            slopdesk_scroll_planner_plan(
                &raw mut *state,
                run.as_ptr(),
                run.len(),
                now,
                out.as_mut_ptr(),
                out.len(),
            )
        };
        out.truncate(written);
        out
    }

    fn travel(emitted: &[SlopDeskPlannedEvent]) -> f64 {
        emitted.iter().map(|planned| planned.event.dy).sum()
    }

    fn flags(message_type: u8, needs_raise: bool) -> u32 {
        slopdesk_input_raise_flags(
            SlopDeskInputEvent {
                message_type,
                ..SlopDeskInputEvent::default()
            },
            needs_raise,
        )
    }

    /// A button-down raises whatever the latch says; a bare move only raises when it is armed.
    #[test]
    fn a_button_down_always_raises_and_a_move_only_pays_for_an_armed_latch() {
        assert_eq!(flags(2, false) & INPUT_RAISE_ALWAYS, INPUT_RAISE_ALWAYS);
        assert_eq!(flags(2, false) & INPUT_RAISE_FIRST, INPUT_RAISE_FIRST);
        assert_eq!(flags(1, false) & INPUT_RAISE_FIRST, 0);
        assert_eq!(flags(1, true) & INPUT_RAISE_FIRST, INPUT_RAISE_FIRST);
    }

    /// A scroll never pays for the raise chain, even armed — and it does not satisfy the latch.
    #[test]
    fn an_armed_latch_never_makes_a_scroll_pay_for_a_raise() {
        assert_eq!(
            flags(4, true) & INPUT_RAISE_LATCH_EXEMPT,
            INPUT_RAISE_LATCH_EXEMPT
        );
        assert_eq!(flags(4, true) & INPUT_RAISE_FIRST, 0);
    }

    /// A mouse-up ends the interaction, so the NEXT event re-raises; nothing else does.
    #[test]
    fn only_a_mouse_up_re_arms_the_latch() {
        assert_eq!(flags(3, false) & INPUT_RAISE_REARM, INPUT_RAISE_REARM);
        for message_type in [1, 2, 4, 5, 6, 7] {
            assert_eq!(flags(message_type, false) & INPUT_RAISE_REARM, 0);
        }
    }

    /// A record no arm answers to raises rather than slipping a click into an unfocused window.
    #[test]
    fn an_unreadable_record_errs_toward_raising() {
        assert_eq!(
            flags(9, false),
            INPUT_RAISE_FIRST | INPUT_RAISE_ALWAYS | INPUT_RAISE_REARM
        );
    }

    /// The chain is skipped ONLY for a settled, already-frontmost app.
    #[test]
    fn the_raise_chain_is_skipped_only_for_a_settled_already_frontmost_app() {
        assert!(!slopdesk_input_should_raise(true, 42, 42, false));
        assert!(
            slopdesk_input_should_raise(true, 42, 42, true),
            "the first one always raises"
        );
        assert!(
            slopdesk_input_should_raise(true, 7, 42, false),
            "another app is frontmost"
        );
        assert!(
            slopdesk_input_should_raise(false, 0, 42, false),
            "an unknown frontmost reads as raise, not as a match on a sentinel pid",
        );
    }

    /// A lost mouse-up leaves a button held, and the next down releases it before it clicks.
    #[test]
    fn a_down_for_a_still_held_button_releases_it_first() {
        let down = SlopDeskInputEvent {
            message_type: 2,
            ..SlopDeskInputEvent::default()
        };
        let first = slopdesk_input_balance_plan(SlopDeskInputBalance::default(), down);
        assert!(!first.has_pre_release);
        assert_eq!(first.state.buttons, 1, "the left button is bit zero");
        let second = slopdesk_input_balance_plan(first.state, down);
        assert!(second.has_pre_release);
        assert_eq!(second.pre_release, 0);
        assert_eq!(second.state.buttons, 1, "the fresh down then owns the button");
    }

    /// The client's redundant up burst posts exactly once, which is the whole point of the ledger.
    #[test]
    fn the_redundant_up_burst_posts_exactly_once() {
        let up = SlopDeskInputEvent {
            message_type: 3,
            ..SlopDeskInputEvent::default()
        };
        let down = SlopDeskInputEvent {
            message_type: 2,
            ..SlopDeskInputEvent::default()
        };
        let held = slopdesk_input_balance_plan(SlopDeskInputBalance::default(), down).state;
        let first = slopdesk_input_balance_plan(held, up);
        assert!(!first.suppress);
        assert_eq!(first.state.buttons, 0);
        assert!(
            slopdesk_input_balance_plan(first.state, up).suppress,
            "an up for a button that is not held is a duplicate",
        );
    }

    /// A modifier burst collapses to one post; an ordinary key and caps lock pass through.
    #[test]
    fn a_modifier_burst_collapses_but_an_ordinary_key_passes_through() {
        let key = |key_code: u16, down: bool| {
            SlopDeskInputEvent {
                message_type: 5,
                key_code,
                down,
                ..SlopDeskInputEvent::default()
            }
        };
        let shift = 56;
        let first = slopdesk_input_balance_plan(SlopDeskInputBalance::default(), key(shift, true));
        assert!(!first.suppress);
        assert!(
            slopdesk_input_balance_plan(first.state, key(shift, true)).suppress,
            "an already-latched modifier down is a no-op",
        );
        let released = slopdesk_input_balance_plan(first.state, key(shift, false));
        assert!(!released.suppress);
        assert_eq!(released.state.modifiers, 0);
        assert!(slopdesk_input_balance_plan(released.state, key(shift, false)).suppress);
        for pass_through in [key(0, true), key(57, true)] {
            let plan = slopdesk_input_balance_plan(SlopDeskInputBalance::default(), pass_through);
            assert!(
                !plan.suppress,
                "an ordinary key and caps lock are never deduplicated"
            );
            assert_eq!(plan.state, SlopDeskInputBalance::default());
        }
    }

    /// A record no arm answers to moves nothing and suppresses nothing.
    #[test]
    fn an_unreadable_record_leaves_the_ledger_where_it_was() {
        let held = SlopDeskInputBalance {
            buttons: 0b101,
            modifiers: 0b1_0001,
        };
        let plan = slopdesk_input_balance_plan(held, SlopDeskInputEvent {
            message_type: 9,
            ..SlopDeskInputEvent::default()
        });
        assert_eq!(plan.state, held);
        assert!(!plan.suppress);
        assert!(!plan.has_pre_release);
    }

    /// The metering survives the crossing: twenty deltas inside one gate window are one emit, the
    /// rest is still held in the state the caller carried back, and no travel is lost.
    #[test]
    fn the_planner_meters_scroll_across_the_boundary_without_losing_travel() {
        let mut state = slopdesk_scroll_planner_new(0.008, true);
        let mut emitted = Vec::new();
        // The clock walks by addition: a fused multiply-add is a different number, and this suite
        // asserts on exact sums.
        let mut now = 1.0;
        for _ in 0..20 {
            emitted.extend(plan_run(&mut state, &[scroll(-5.0)], now));
            now += 0.0001;
        }
        assert_eq!(emitted.len(), 1, "one emit per interval, not twenty posts");
        assert!(state.has_template, "the rest is still held");
        emitted.extend(plan_run(&mut state, &[], 2.0));
        assert_eq!(travel(&emitted), -100.0, "and no travel was dropped");
        assert!(!state.has_template);
    }

    /// A passed-through event is named, never rebuilt — that is what keeps a text payload home.
    #[test]
    fn a_passed_through_event_is_named_and_a_summed_emit_is_not() {
        let mut state = slopdesk_scroll_planner_new(100.0, true);
        plan_run(&mut state, &[scroll(-5.0)], 0.0);
        let text = SlopDeskInputEvent {
            message_type: 6,
            ..SlopDeskInputEvent::default()
        };
        let out = plan_run(&mut state, &[text], 0.1);
        assert_eq!(out.len(), 2, "the residual flushes before the barrier");
        assert!(!out[0].has_source, "the summed emit is the planner's own event");
        assert!(out[1].has_source, "the text event is the caller's");
        assert_eq!(out[1].source, 0);
    }

    /// A caller that lent too little gets the count it should have lent and a planner that has NOT
    /// moved, so its retry folds the run once rather than twice.
    #[test]
    fn a_short_lend_reports_the_count_and_leaves_the_planner_where_it_was() {
        let mut state = slopdesk_scroll_planner_new(0.0, true);
        let before = state;
        let needed = unsafe {
            slopdesk_scroll_planner_plan(
                &raw mut state,
                [scroll(-5.0)].as_ptr(),
                1,
                1.0,
                core::ptr::null_mut(),
                0,
            )
        };
        assert_eq!(needed, 1);
        assert_eq!(state, before, "a measuring call folds nothing");
    }

    /// A teardown drops the tail rather than leaking it into the next session.
    #[test]
    fn clearing_drops_the_residual_without_emitting_it() {
        let mut state = slopdesk_scroll_planner_new(100.0, true);
        plan_run(&mut state, &[scroll(-5.0)], 0.0);
        assert!(state.has_template);
        let cleared = slopdesk_scroll_planner_clear(state);
        assert!(!cleared.has_template);
        assert_eq!(cleared.accumulated_dy, 0.0);
        assert_eq!(
            cleared.inject_interval, state.inject_interval,
            "the settings are configuration, not state",
        );
    }
}
