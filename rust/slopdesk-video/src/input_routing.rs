//! What happens to a client input datagram between the socket and the injector.
//!
//! Four pure stages, none of which touches a real event: decide whether the target window must be
//! raised first; collapse the motion flood; keep the button and modifier ledger balanced; and meter
//! the continuous scroll accumulator. Every one of them exists because the injection itself is
//! expensive — the host posts each event behind SYNCHRONOUS window-server round-trips, and the
//! raise chain behind several cross-process accessibility calls — so the volume has to come down
//! before it reaches that boundary.
//!
//! The datagram's own gate is NOT here. Whether the session is streaming, and what to log when it
//! is not, is the caller's; the decode is one door already; and the raise rule below is the third
//! part. A `route` that folded the three would be a fourth spelling of decisions that each already
//! have exactly one.

use std::collections::BTreeSet;

use crate::input_event::{InputEvent, MouseButton, ScrollEvent, modifier_keys};

/// Whether an event ALWAYS raises and focuses the target first.
///
/// A pointer button-down does; pure moves, scrolls, keys and text do not, so focus is not yanked on
/// every keystroke.
#[must_use]
pub const fn always_raises(event: &InputEvent) -> bool {
    matches!(*event, InputEvent::MouseDown(..))
}

/// Whether, after injecting this event, the NEXT one should be forced to raise.
///
/// A mouse-up ends an interaction, so the next event re-raises; otherwise the latch is cleared once
/// any event has been injected.
#[must_use]
pub const fn rearm_raise_after(event: &InputEvent) -> bool {
    matches!(*event, InputEvent::MouseUp(..))
}

/// Whether an event is EXEMPT from the armed raise latch.
///
/// A scroll is dispatched by the window server to the window UNDER THE CURSOR regardless of key
/// focus, so it never needs the expensive re-raise — even with the post-click latch armed. Without
/// the exemption a click-a-pane-then-scroll gesture pays a full accessibility raise on that first
/// scroll and the scroll feels delayed. A button-down still always raises, and a key with the latch
/// armed still raises, because that one genuinely needs key focus. An exempt scroll does NOT
/// satisfy the raise, so the caller never clears the latch on it and a key arriving AFTER the
/// scroll still re-raises.
#[must_use]
pub const fn latch_exempt_from_raise(event: &InputEvent) -> bool {
    matches!(*event, InputEvent::Scroll(..))
}

/// The single rule the caller's latch is read by: should this event raise and focus the target
/// before injection.
#[must_use]
pub const fn raise_first(event: &InputEvent, needs_raise: bool) -> bool {
    (needs_raise && !latch_exempt_from_raise(event)) || always_raises(event)
}

/// Whether to run the full accessibility raise chain at all.
///
/// That chain is several SYNCHRONOUS cross-process calls, each capped at the messaging timeout, and
/// the input consumer awaits them before the click is posted — so paying it on every click of an
/// already-frontmost window is the dominant felt input latency. This decides from a CHEAP
/// frontmost-app read whether it is actually needed, and errs toward raising on any uncertainty, so
/// activate-then-control correctness is never weakened.
///
/// The first interaction always raises, even when the app is already frontmost, because that is
/// what sets the main and focused window so keystrokes land on the right one.
#[must_use]
pub const fn should_raise(frontmost_pid: Option<i32>, target_pid: i32, first_interaction: bool) -> bool {
    if first_interaction {
        return true;
    }
    match frontmost_pid {
        None => true, // an unknown frontmost reads as raise, to be safe
        Some(pid) => pid != target_pid,
    }
}

/// What to do before injecting one event.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct InjectionPlan {
    /// Emit a synthetic release of THIS button before the real event.
    ///
    /// Set only when a button-down arrives for a button still marked held, which means its up was
    /// lost.
    pub pre_release: Option<MouseButton>,
    /// SUPPRESS the event entirely — do not post it.
    ///
    /// Set for an up whose button is NOT held: either a duplicate of the client's loss-resilient
    /// repeated up, where the first already released it, or an up with no matching down. Posting it
    /// would be a spurious extra release into the target app, which breaks its double-click
    /// coalescing and any custom tracking. This is what makes the wire redundancy idempotent at the
    /// host: the FIRST up of a burst posts and the rest are dropped.
    pub suppress: bool,
}

/// The button and modifier ledger for input injection.
///
/// The ordered inbound consumer keeps a single interaction's down, drag and up in order, but it
/// cannot conjure a mouse-up the wire DROPPED or a flaky gesture never sent. A target app that got
/// a down with no matching up stays stuck mid-selection, so the NEXT click lands inside an
/// already-started selection. This tracks what is logically HELD so a fresh down for an
/// already-held button emits a synthetic release FIRST.
///
/// Modifier key edges get the same idempotence, for the mirror-image reason: the client sends a
/// modifier release REDUNDANTLY, because a lost release latches the modifier on the shared event
/// source until the user presses it again. Ordinary keys, whose auto-repeat is identical downs, and
/// the caps-lock toggle, whose state would desync from the host's actual one if tracked by edge,
/// pass through verbatim.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct InputButtonBalance {
    /// The logically-held buttons.
    held: BTreeSet<MouseButton>,
    /// The logically-held MODIFIER keys, keyed on the exact code, so the left and right variants
    /// stay distinct latched flags.
    held_modifier_keys: BTreeSet<u16>,
}

impl InputButtonBalance {
    /// An empty ledger.
    #[must_use]
    pub const fn new() -> Self {
        Self {
            held: BTreeSet::new(),
            held_modifier_keys: BTreeSet::new(),
        }
    }

    /// The logically-held buttons.
    #[must_use]
    pub const fn held(&self) -> &BTreeSet<MouseButton> {
        &self.held
    }

    /// The logically-held modifier key codes.
    #[must_use]
    pub const fn held_modifier_keys(&self) -> &BTreeSet<u16> {
        &self.held_modifier_keys
    }

    /// The ledger as the twelve bits it really is: one per button, one per held modifier key.
    ///
    /// Both domains are FIXED — three buttons the wire admits, nine modifier keycodes — so the
    /// whole ledger is a pair of masks, which is what lets a caller that owns the state by
    /// value carry it across a boundary and back without a handle (`docs/55` §4b). The modifier
    /// bit is the key's position in [`modifier_keys::HELD_MODIFIER_KEY_CODES`], so the table
    /// stays the only place that says which keys these are.
    #[must_use]
    pub fn masks(&self) -> (u8, u16) {
        let buttons = self
            .held
            .iter()
            .fold(0_u8, |mask, button| mask | (1 << button.raw_value()));
        let modifiers = self.held_modifier_keys.iter().fold(0_u16, |mask, code| {
            modifier_keys::HELD_MODIFIER_KEY_CODES
                .iter()
                .position(|held| held == code)
                .map_or(mask, |bit| mask | (1 << bit))
        });
        (buttons, modifiers)
    }

    /// The ledger back from its masks — the exact inverse of [`masks`](Self::masks). A bit with no
    /// button or keycode behind it is ignored, which is the same answer an empty ledger gives.
    #[must_use]
    pub fn from_masks(buttons: u8, modifiers: u16) -> Self {
        Self {
            held: (0..3)
                .filter(|bit| buttons & (1 << bit) != 0)
                .filter_map(MouseButton::from_raw)
                .collect(),
            held_modifier_keys: modifier_keys::HELD_MODIFIER_KEY_CODES
                .iter()
                .enumerate()
                .filter(|(bit, _)| modifiers & (1 << bit) != 0)
                .map(|(_, code)| *code)
                .collect(),
        }
    }

    /// Folds one event into the ledger and returns its injection plan.
    ///
    /// A down for an already-held button asks for a pre-release and then STAYS held, because the
    /// fresh down owns it. An up for a held button releases it and posts. An up for a button that
    /// is not held is a duplicate and is suppressed. Everything else passes through.
    pub fn plan(&mut self, event: &InputEvent) -> InjectionPlan {
        match *event {
            InputEvent::MouseDown(mouse, _) => {
                let stuck = !self.held.insert(mouse.button);
                InjectionPlan {
                    pre_release: stuck.then_some(mouse.button),
                    suppress: false,
                }
            },
            InputEvent::MouseUp(mouse, _) => {
                InjectionPlan {
                    pre_release: None,
                    suppress: !self.held.remove(&mouse.button),
                }
            },
            InputEvent::Key(key, _) => {
                if !modifier_keys::is_held_modifier(key.key_code) {
                    return InjectionPlan::default();
                }
                if key.down {
                    // A down for an already-down modifier — a refocus resync against a still-latched
                    // host flag — is a no-op, because that flag is already correct.
                    return InjectionPlan {
                        pre_release: None,
                        suppress: !self.held_modifier_keys.insert(key.key_code),
                    };
                }
                InjectionPlan {
                    pre_release: None,
                    suppress: !self.held_modifier_keys.remove(&key.key_code),
                }
            },
            InputEvent::MouseMove { .. }
            | InputEvent::MouseDrag(..)
            | InputEvent::Scroll(..)
            | InputEvent::Text(..) => InjectionPlan::default(),
        }
    }
}

/// A coalescible run's key.
///
/// Move and drag NEVER merge: a class change is a flush boundary, because a drag carries a held
/// button and its click state while a move is a bare hover, so collapsing across the boundary would
/// drop the transition the target app needs. Scroll is keyed by its PHASE signature, so a gesture's
/// start or end singleton never merges into the bulk run — only consecutive same-phase scrolls
/// merge, by SUMMING their additive deltas.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum RunKey {
    /// A bare hover run.
    Move,
    /// A held-button drag run.
    Drag,
    /// A same-phase scroll run.
    Scroll {
        /// The gesture phase.
        phase: u8,
        /// The momentum phase.
        momentum: u8,
        /// Whether the deltas are pixel-precise.
        continuous: bool,
    },
}

/// The run key an event belongs to, or `None` when it is a hard BARRIER.
fn run_key(event: &InputEvent, coalesce_scroll: bool) -> Option<RunKey> {
    match *event {
        InputEvent::MouseMove { .. } => Some(RunKey::Move),
        InputEvent::MouseDrag(..) => Some(RunKey::Drag),
        // A fast trackpad scroll and its momentum coast are a flood; uncoalesced, each becomes one
        // synchronous post, which saturates the window server and stalls CAPTURE — a measured
        // capture gap and a far longer send gap, which is the reversal hitch. When the knob is off,
        // scroll stays a hard barrier.
        InputEvent::Scroll(scroll, _) => {
            coalesce_scroll.then_some(RunKey::Scroll {
                phase: scroll.scroll_phase,
                momentum: scroll.momentum_phase,
                continuous: scroll.continuous,
            })
        },
        InputEvent::MouseDown(..) | InputEvent::MouseUp(..) | InputEvent::Key(..) | InputEvent::Text(..) => {
            None
        },
    }
}

/// One output event of a coalesced batch, named by WHERE it came from rather than by carrying it.
///
/// The run rule never invents an event: a surviving move or drag IS the run's last input, and a
/// merged scroll is the run's last input with its deltas replaced by the run's sum. So a plan of
/// `{source, dx, dy}` says everything a caller needs to rebuild the batch from the events it is
/// already holding — which is what lets this cross a C ABI without a text payload having to.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct CoalescedSlot {
    /// The index in the input batch this output event is built from.
    pub source: usize,
    /// The horizontal delta the output carries — the run's SUM for a merged scroll, the event's own
    /// otherwise, and zero for anything that has none.
    pub dx: f64,
    /// The vertical delta, on the same terms.
    pub dy: f64,
}

/// The deltas an event carries in its own right; zero for the arms that carry none.
const fn deltas_of(event: &InputEvent) -> (f64, f64) {
    match *event {
        InputEvent::Scroll(scroll, _) => (scroll.dx, scroll.dy),
        _ => (0.0, 0.0),
    }
}

/// The event rebuilt from its slot: a scroll takes the slot's deltas, everything else is itself.
fn with_deltas(event: InputEvent, dx: f64, dy: f64) -> InputEvent {
    match event {
        InputEvent::Scroll(scroll, tag) => InputEvent::Scroll(ScrollEvent { dx, dy, ..scroll }, tag),
        other => other,
    }
}

/// The coalesced batch as a PLAN — see [`coalesce_motion`] for the rule this is the one statement
/// of, and [`CoalescedSlot`] for why the answer names events instead of carrying them.
///
/// The slots come out in output order and their `source` indices strictly increase, so a caller may
/// walk its batch and this answer together in one pass.
#[must_use]
pub fn coalesce_plan(batch: &[InputEvent], coalesce_scroll: bool) -> Vec<CoalescedSlot> {
    let mut output = Vec::with_capacity(batch.len());
    let mut pending: Option<(CoalescedSlot, RunKey)> = None;
    for (source, event) in batch.iter().enumerate() {
        let (dx, dy) = deltas_of(event);
        let Some(key) = run_key(event, coalesce_scroll) else {
            // A barrier: flush any buffered motion FIRST, then the barrier itself.
            if let Some((held, _)) = pending.take() {
                output.push(held);
            }
            output.push(CoalescedSlot { source, dx, dy });
            continue;
        };
        let fresh = match pending.take() {
            // Scroll SUMS — the deltas are additive, so summing preserves total travel; move and
            // drag keep the latest, because an absolute position supersedes the older ones.
            Some((held, held_key)) if held_key == key => {
                match key {
                    RunKey::Scroll { .. } => {
                        CoalescedSlot {
                            source,
                            dx: held.dx + dx,
                            dy: held.dy + dy,
                        }
                    },
                    RunKey::Move | RunKey::Drag => CoalescedSlot { source, dx, dy },
                }
            },
            Some((held, _)) => {
                output.push(held); // a class or phase change flushes the old run
                CoalescedSlot { source, dx, dy }
            },
            None => CoalescedSlot { source, dx, dy },
        };
        pending = Some((fresh, key));
    }
    if let Some((held, _)) = pending {
        output.push(held); // the trailing run
    }
    output
}

/// Collapses consecutive same-class motion runs to their latest, preserving the relative order of
/// every barrier event and of motion against barriers.
///
/// A remote pointer stream is almost all motion — a real trace carries well over a hundred moves
/// per button event — and the host injects every one behind synchronous window-server round-trips,
/// so when the serial consumer falls behind a flood it replays every STALE intermediate position in
/// order and the cursor crawls seconds behind the user.
///
/// The invariant: a button, key, text or uncoalesced scroll event is a HARD BARRIER, and any
/// buffered motion flushes BEFORE it, so a move that physically preceded a click is never emitted
/// after the click. That keeps the down-drag-up framing, the button ledger and the stateless-drag
/// contract intact — every down and up still reaches the injector exactly once, in order.
///
/// Driven by drain availability rather than a timer, this is SELF-REGULATING: when the consumer
/// keeps up the batches are one event long and it is a no-op, and only when it falls behind does a
/// run collapse, bounding the lag to about one injection regardless of the flood.
#[must_use]
pub fn coalesce_motion(batch: Vec<InputEvent>, coalesce_scroll: bool) -> Vec<InputEvent> {
    if batch.len() <= 1 {
        return batch;
    }
    let mut slots = coalesce_plan(&batch, coalesce_scroll).into_iter().peekable();
    let mut output = Vec::with_capacity(batch.len());
    // The plan's sources strictly increase, so one walk of the batch answers it: an index the plan
    // does not name was merged into a later slot, and is dropped by not being taken.
    for (index, event) in batch.into_iter().enumerate() {
        let Some(&slot) = slots.peek() else { break };
        if slot.source != index {
            continue;
        }
        let _ = slots.next();
        output.push(with_deltas(event, slot.dx, slot.dy));
    }
    output
}

/// Whether a scroll phase pair is one the accumulator may hold.
///
/// Only the high-frequency CONTINUOUS phases accumulate: a finger drag, or an inertial coast. Every
/// gesture boundary, and a discrete wheel tick, is emitted immediately after flushing whatever was
/// held, so the gesture STRUCTURE and the total travel both stay exact.
#[must_use]
pub const fn is_coalescable_scroll_phase(scroll_phase: u8, momentum_phase: u8) -> bool {
    scroll_phase == 2 || momentum_phase == 2
}

/// One event the planner wants injected, and where it came from.
///
/// `source` names the input it IS — the caller holds that event already, so nothing of it has to
/// cross — while `None` marks the planner's own summed emit, which is a scroll and therefore has
/// nothing in it that cannot be spelled in scalars.
#[derive(Debug, Clone, PartialEq)]
pub struct PlannedSlot {
    /// The index in the run this event is, or `None` for a summed emit.
    pub source: Option<usize>,
    /// The event to inject.
    pub event: InputEvent,
}

/// What a scroll accumulator carries between runs.
///
/// Every field is a number or a scroll, because a summed emit is the planner's OWN event and a
/// scroll has nothing in it that needs a heap — which is what lets the whole fold cross by value.
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct ScrollAccumulator {
    /// The summed horizontal travel.
    pub dx: f64,
    /// The summed vertical travel.
    pub dy: f64,
    /// The phase, position and tag the summed emit is stamped with, or `None` when nothing is held.
    pub template: Option<(ScrollEvent, u32)>,
    /// When the last emit went out, on the caller's clock.
    pub last_inject_at: f64,
}

/// The time-gated scroll accumulator.
///
/// Continuous scroll deltas are SUMMED into an accumulator held ACROSS drains and emitted at most
/// once per interval, because uncoalesced the flood saturates the window server and stalls capture.
/// A gesture boundary or any non-scroll event flushes the accumulator FIRST, in order; a trailing
/// flush covers a run that ends mid-gesture.
///
/// The plan is the exact ordered list of events to inject, and the caller applies its raise latch
/// per returned event, so the raise and button-balance semantics are untouched by the metering.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ScrollCoalescePlanner {
    /// The summed horizontal travel.
    accumulated_dx: f64,
    /// The summed vertical travel.
    accumulated_dy: f64,
    /// The newest phase, precision and tag template for the summed emit, or `None` when nothing is
    /// accumulated.
    template: Option<(ScrollEvent, u32)>,
    /// When the last emit went out.
    last_inject_at: f64,
    /// The minimum spacing between emits.
    inject_interval: f64,
    /// Whether scroll coalescing is armed at all.
    coalesce_scroll: bool,
}

impl ScrollCoalescePlanner {
    /// A planner with nothing accumulated.
    #[must_use]
    pub const fn new(inject_interval: f64, coalesce_scroll: bool) -> Self {
        Self {
            accumulated_dx: 0.0,
            accumulated_dy: 0.0,
            template: None,
            last_inject_at: 0.0,
            inject_interval,
            coalesce_scroll,
        }
    }

    /// Whether a summed residual is currently held, which drives the caller's idle-flush re-arm.
    #[must_use]
    pub const fn has_pending_scroll(&self) -> bool {
        self.template.is_some()
    }

    /// Everything the fold carries between runs, for a caller that holds the planner BY VALUE and
    /// has to carry it across a boundary — the same reason the ledger has its masks. The two
    /// settings are not in it: they are the planner's configuration, not its state, and a caller
    /// that could rewrite them mid-gesture could change the gate under a held residual.
    #[must_use]
    pub const fn accumulator(&self) -> ScrollAccumulator {
        ScrollAccumulator {
            dx: self.accumulated_dx,
            dy: self.accumulated_dy,
            template: self.template,
            last_inject_at: self.last_inject_at,
        }
    }

    /// A planner mid-fold: its settings, plus the state a previous run left behind.
    #[must_use]
    pub const fn restored(inject_interval: f64, coalesce_scroll: bool, held: ScrollAccumulator) -> Self {
        Self {
            accumulated_dx: held.dx,
            accumulated_dy: held.dy,
            template: held.template,
            last_inject_at: held.last_inject_at,
            inject_interval,
            coalesce_scroll,
        }
    }

    /// Drops any pending residual WITHOUT emitting it, for a media teardown: a stale gesture tail
    /// must not leak into the next session.
    pub const fn clear_pending(&mut self) {
        self.accumulated_dx = 0.0;
        self.accumulated_dy = 0.0;
        self.template = None;
    }

    /// Folds one arrival-ordered run and returns the events to inject NOW.
    ///
    /// There is deliberately NO early return for an empty run: a drain that carried only control or
    /// recovery datagrams must still reach the trailing flush, or a residual stranded by a LOST
    /// gesture-end datagram would wait for the next unrelated input event.
    ///
    /// The `now` clock is sampled once per run by the caller — a run folds in microseconds, far
    /// below the millisecond-scale gate, so per-event sampling would be indistinguishable.
    pub fn plan(&mut self, run: &[InputEvent], now: f64) -> Vec<InputEvent> {
        self.plan_slots(run, now)
            .into_iter()
            .map(|slot| slot.event)
            .collect()
    }

    /// The same fold, answering WHERE each event came from — see [`PlannedSlot`].
    ///
    /// A caller across a boundary needs the provenance: a passed-through event is one it is already
    /// holding, text payload and all, while a summed emit is this side's own and carries nothing
    /// that cannot be spelled in scalars.
    pub fn plan_slots(&mut self, run: &[InputEvent], now: f64) -> Vec<PlannedSlot> {
        let mut out = Vec::new();
        for slot in coalesce_plan(run, self.coalesce_scroll) {
            let Some(event) = run
                .get(slot.source)
                .map(|event| with_deltas(event.clone(), slot.dx, slot.dy))
            else {
                continue;
            };
            if self.coalesce_scroll
                && let InputEvent::Scroll(scroll, tag) = event
                && is_coalescable_scroll_phase(scroll.scroll_phase, scroll.momentum_phase)
            {
                self.accumulate(scroll, tag, now, &mut out);
                continue;
            }
            // A gesture boundary or a non-scroll event flushes first, preserving order.
            self.flush_pending(&mut out);
            out.push(PlannedSlot {
                source: Some(slot.source),
                event,
            });
        }
        // A trailing flush, so continuous scroll that ended this run without a boundary is not
        // stranded past the gate — but only once the gate has elapsed, else it holds for the next
        // run to keep the one-per-interval cap.
        if self.template.is_some() && now - self.last_inject_at >= self.inject_interval {
            self.last_inject_at = now;
            self.flush_pending(&mut out);
        }
        out
    }

    /// Folds one coalescable scroll into the accumulator, emitting when the gate has elapsed.
    fn accumulate(&mut self, scroll: ScrollEvent, tag: u32, now: f64, out: &mut Vec<PlannedSlot>) {
        // A PHASE-DOMAIN boundary: an on-glass residual must never merge with a momentum delta,
        // because the summed emit carries ONE phase pair, so the older domain's marker would be
        // silently rewritten and on-glass travel would replay as momentum. This is unreachable in a
        // complete gesture, where the boundary events flush between the domains; it exists for the
        // DUAL-LOSS case where both of those datagrams drop on the fire-and-forget input channel.
        if let Some((held, _)) = self.template
            && (held.scroll_phase != scroll.scroll_phase || held.momentum_phase != scroll.momentum_phase)
        {
            self.flush_pending(out);
        }
        self.accumulated_dx += scroll.dx;
        self.accumulated_dy += scroll.dy;
        self.template = Some((
            ScrollEvent {
                dx: 0.0,
                dy: 0.0,
                ..scroll
            },
            tag,
        ));
        if now - self.last_inject_at >= self.inject_interval {
            self.last_inject_at = now;
            self.flush_pending(out);
        }
    }

    /// Emits the accumulated travel as ONE event and clears the accumulator. A no-op when nothing
    /// is held. Total travel is preserved, because the deltas are additive.
    fn flush_pending(&mut self, out: &mut Vec<PlannedSlot>) {
        let Some((template, tag)) = self.template.take() else {
            return;
        };
        out.push(PlannedSlot {
            // A summed emit is this side's own event, not one of the caller's.
            source: None,
            event: InputEvent::Scroll(
                ScrollEvent {
                    dx: self.accumulated_dx,
                    dy: self.accumulated_dy,
                    ..template
                },
                tag,
            ),
        });
        self.accumulated_dx = 0.0;
        self.accumulated_dy = 0.0;
    }
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::panic,
        clippy::float_cmp,
        reason = "the travel assertions are on sums the law pins exactly, which is the property under test"
    )]

    use super::{
        InputButtonBalance, ScrollCoalescePlanner, always_raises, coalesce_motion, coalesce_plan,
        is_coalescable_scroll_phase, latch_exempt_from_raise, raise_first, rearm_raise_after, should_raise,
        with_deltas,
    };
    use crate::geometry::VideoPoint;
    use crate::input_event::{
        InputEvent, InputModifiers, KeyEvent, MouseButton, MouseButtonEvent, ScrollEvent, modifier_keys,
    };

    const ORIGIN: VideoPoint = VideoPoint { x: 0.5, y: 0.5 };

    fn button(button: MouseButton) -> MouseButtonEvent {
        MouseButtonEvent {
            button,
            normalized: ORIGIN,
            click_count: 1,
            modifiers: InputModifiers::default(),
        }
    }

    fn down(which: MouseButton) -> InputEvent {
        InputEvent::MouseDown(button(which), 0)
    }

    fn up(which: MouseButton) -> InputEvent {
        InputEvent::MouseUp(button(which), 0)
    }

    fn mouse_move(x: f64) -> InputEvent {
        InputEvent::MouseMove {
            normalized: VideoPoint { x, y: 0.5 },
            tag: 0,
        }
    }

    fn scroll(dy: f64, phase: u8, momentum: u8) -> InputEvent {
        InputEvent::Scroll(
            ScrollEvent {
                dx: 0.0,
                dy,
                normalized: ORIGIN,
                scroll_phase: phase,
                momentum_phase: momentum,
                continuous: true,
            },
            0,
        )
    }

    fn key(key_code: u16, is_down: bool) -> InputEvent {
        InputEvent::Key(
            KeyEvent {
                key_code,
                down: is_down,
                modifiers: InputModifiers::default(),
            },
            0,
        )
    }

    /// The total vertical travel across a plan, which every coalesce must preserve.
    fn travel(events: &[InputEvent]) -> f64 {
        events
            .iter()
            .map(|event| {
                match *event {
                    InputEvent::Scroll(scroll, _) => scroll.dy,
                    _ => 0.0,
                }
            })
            .sum()
    }

    #[test]
    fn a_button_down_always_raises_but_a_bare_move_does_not() {
        assert!(always_raises(&down(MouseButton::Left)));
        assert!(!always_raises(&mouse_move(0.5)));
        assert!(
            raise_first(&mouse_move(0.5), true),
            "the armed latch raises a move"
        );
        assert!(!raise_first(&mouse_move(0.5), false));
    }

    /// The measured cost this exemption removes: a full accessibility raise on the first scroll
    /// after a click.
    #[test]
    fn an_armed_latch_never_makes_a_scroll_pay_for_a_raise() {
        let scroll = scroll(-10.0, 2, 0);
        assert!(latch_exempt_from_raise(&scroll));
        assert!(!raise_first(&scroll, true), "exempt even with the latch armed");
        assert!(
            raise_first(&key(0, true), true),
            "but a key still raises — it needs key focus",
        );
    }

    #[test]
    fn a_mouse_up_re_arms_the_latch_so_the_next_click_re_raises() {
        assert!(rearm_raise_after(&up(MouseButton::Left)));
        assert!(!rearm_raise_after(&down(MouseButton::Left)));
        assert!(!rearm_raise_after(&mouse_move(0.5)));
    }

    #[test]
    fn the_raise_chain_is_skipped_only_for_a_settled_already_frontmost_app() {
        assert!(
            should_raise(Some(42), 42, true),
            "the first interaction always raises"
        );
        assert!(!should_raise(Some(42), 42, false));
        assert!(should_raise(Some(7), 42, false), "a different app raises");
        assert!(should_raise(None, 42, false), "and so does an unknown frontmost");
    }

    /// The stuck-selection failure the ledger exists to prevent.
    #[test]
    fn a_down_for_a_still_held_button_releases_it_first() {
        let mut balance = InputButtonBalance::new();
        assert_eq!(balance.plan(&down(MouseButton::Left)).pre_release, None);
        // The up was lost on the wire; the next down must not land inside the open selection.
        let plan = balance.plan(&down(MouseButton::Left));
        assert_eq!(plan.pre_release, Some(MouseButton::Left));
        assert!(!plan.suppress, "the fresh down still posts, and owns the button");
        assert!(balance.held().contains(&MouseButton::Left));
    }

    #[test]
    fn the_clients_redundant_up_burst_posts_exactly_once() {
        let mut balance = InputButtonBalance::new();
        balance.plan(&down(MouseButton::Left));
        assert!(
            !balance.plan(&up(MouseButton::Left)).suppress,
            "the first up posts"
        );
        assert!(balance.plan(&up(MouseButton::Left)).suppress);
        assert!(balance.plan(&up(MouseButton::Left)).suppress);
        assert!(balance.held().is_empty());
        assert!(
            balance.plan(&up(MouseButton::Right)).suppress,
            "an orphan up with no down is dropped too",
        );
    }

    /// The masks are the ledger, not a summary of it: every state a fold can reach survives the
    /// round trip. A caller that owns the ledger by value carries these twelve bits and nothing
    /// else, so a bit that dropped a held button would post a click inside a stuck selection.
    #[test]
    fn a_ledger_survives_the_crossing_its_masks_are() {
        let mut balance = InputButtonBalance::new();
        for button in [MouseButton::Left, MouseButton::Right, MouseButton::Other] {
            balance.plan(&down(button));
        }
        for code in modifier_keys::HELD_MODIFIER_KEY_CODES {
            balance.plan(&key(code, true));
        }
        let (buttons, modifiers) = balance.masks();
        assert_eq!(InputButtonBalance::from_masks(buttons, modifiers), balance);
        assert_eq!(
            InputButtonBalance::from_masks(0, 0),
            InputButtonBalance::new(),
            "an empty ledger is empty masks",
        );
        assert_eq!(
            InputButtonBalance::from_masks(0xFF, 0xFFFF),
            balance,
            "a bit with no button or keycode behind it is ignored, not invented",
        );
    }

    #[test]
    fn the_buttons_are_tracked_independently() {
        let mut balance = InputButtonBalance::new();
        balance.plan(&down(MouseButton::Left));
        balance.plan(&down(MouseButton::Right));
        assert!(!balance.plan(&up(MouseButton::Left)).suppress);
        assert!(
            !balance.plan(&up(MouseButton::Right)).suppress,
            "the right button's up is not swallowed by the left's release",
        );
    }

    #[test]
    fn a_modifier_burst_collapses_but_an_ordinary_key_passes_through() {
        let mut balance = InputButtonBalance::new();
        let shift = 56; // a held modifier
        assert!(!balance.plan(&key(shift, true)).suppress);
        assert!(
            balance.plan(&key(shift, true)).suppress,
            "an already-latched modifier down is a no-op",
        );
        assert!(!balance.plan(&key(shift, false)).suppress, "the first up posts");
        assert!(
            balance.plan(&key(shift, false)).suppress,
            "the redundant ones do not"
        );
        assert!(balance.held_modifier_keys().is_empty());
        // An ordinary key auto-repeats as identical downs and must never be deduplicated.
        for _ in 0..3 {
            assert!(!balance.plan(&key(0, true)).suppress);
        }
        // Caps lock is a toggle whose state would desync if tracked by edge.
        for _ in 0..3 {
            assert!(!balance.plan(&key(57, true)).suppress);
        }
    }

    #[test]
    fn motion_never_passes_a_click_it_physically_preceded() {
        let batch = vec![
            mouse_move(0.1),
            mouse_move(0.2),
            mouse_move(0.3),
            down(MouseButton::Left),
            mouse_move(0.4),
        ];
        let coalesced = coalesce_motion(batch, false);
        assert_eq!(
            coalesced,
            [mouse_move(0.3), down(MouseButton::Left), mouse_move(0.4)],
            "the run collapses to its latest, and flushes BEFORE the barrier",
        );
    }

    #[test]
    fn a_move_and_a_drag_never_merge_across_the_class_boundary() {
        let drag = InputEvent::MouseDrag(button(MouseButton::Left), 0);
        let coalesced = coalesce_motion(
            vec![mouse_move(0.1), mouse_move(0.2), drag.clone(), drag.clone()],
            false,
        );
        assert_eq!(coalesced, [mouse_move(0.2), drag], "the transition survives");
    }

    #[test]
    fn a_coalesced_scroll_run_sums_its_travel_rather_than_keeping_the_latest() {
        let batch = vec![scroll(-10.0, 2, 0), scroll(-20.0, 2, 0), scroll(-30.0, 2, 0)];
        let coalesced = coalesce_motion(batch, true);
        assert_eq!(coalesced.len(), 1);
        assert_eq!(
            travel(&coalesced),
            -60.0,
            "keep-latest would drop scrolled distance"
        );
    }

    #[test]
    fn a_gesture_boundary_never_merges_into_the_bulk_run() {
        let batch = vec![
            scroll(-1.0, 1, 0), // began
            scroll(-10.0, 2, 0),
            scroll(-10.0, 2, 0),
            scroll(0.0, 4, 0), // ended
        ];
        let coalesced = coalesce_motion(batch, true);
        assert_eq!(coalesced.len(), 3, "began, the summed bulk, ended");
        assert_eq!(travel(&coalesced), -21.0);
    }

    /// The plan is not a second rule: whatever a caller rebuilds from it IS the coalesced batch.
    ///
    /// This is the property the boundary rests on. Swift holds its own events and applies the plan
    /// to them, so if a slot could ever name a different event than the fold keeps, the two sides
    /// would inject different streams while both looked right.
    #[test]
    fn a_batch_rebuilt_from_the_plan_is_the_batch_the_fold_answers() {
        let batch = vec![
            mouse_move(0.1),
            mouse_move(0.2),
            InputEvent::MouseDrag(button(MouseButton::Left), 0),
            scroll(-1.0, 1, 0),
            scroll(-10.0, 2, 0),
            scroll(-20.0, 2, 0),
            down(MouseButton::Left),
            InputEvent::Text("typed".to_owned(), 0),
            mouse_move(0.9),
        ];
        for coalesce_scroll in [false, true] {
            let plan = coalesce_plan(&batch, coalesce_scroll);
            assert!(
                plan.iter()
                    .zip(plan.iter().skip(1))
                    .all(|(a, b)| a.source < b.source),
                "a caller may walk its batch and the plan together only if the sources increase",
            );
            let rebuilt: Vec<InputEvent> = plan
                .iter()
                .filter_map(|slot| {
                    batch
                        .get(slot.source)
                        .map(|event| with_deltas(event.clone(), slot.dx, slot.dy))
                })
                .collect();
            assert_eq!(rebuilt, coalesce_motion(batch.clone(), coalesce_scroll));
        }
    }

    #[test]
    fn with_the_knob_off_a_scroll_stays_a_hard_barrier() {
        let batch = vec![scroll(-10.0, 2, 0), scroll(-20.0, 2, 0)];
        assert_eq!(coalesce_motion(batch.clone(), false), batch);
    }

    #[test]
    fn only_the_continuous_phases_accumulate() {
        assert!(is_coalescable_scroll_phase(2, 0), "a finger drag");
        assert!(is_coalescable_scroll_phase(0, 2), "an inertial coast");
        assert!(!is_coalescable_scroll_phase(1, 0), "a gesture start");
        assert!(!is_coalescable_scroll_phase(4, 0), "a gesture end");
        assert!(!is_coalescable_scroll_phase(0, 0), "a discrete wheel tick");
    }

    #[test]
    fn the_planner_meters_scroll_to_one_emit_per_interval_without_losing_travel() {
        let mut planner = ScrollCoalescePlanner::new(0.008, true);
        let mut emitted = Vec::new();
        // Twenty deltas inside one gate window: they sum, and only the first crosses the gate.
        for step in 0..20 {
            emitted.extend(planner.plan(&[scroll(-5.0, 2, 0)], 1.0 + f64::from(step) * 0.0001));
        }
        assert_eq!(emitted.len(), 1, "one emit per interval, not twenty posts");
        assert!(planner.has_pending_scroll(), "the rest is still held");
        emitted.extend(planner.plan(&[], 2.0));
        assert_eq!(travel(&emitted), -100.0, "and no travel was dropped");
    }

    /// The stranded-residual case an empty-run early return would reintroduce.
    #[test]
    fn an_empty_run_still_reaches_the_trailing_flush() {
        let mut planner = ScrollCoalescePlanner::new(1.0, true);
        planner.plan(&[scroll(-5.0, 2, 0)], 0.0);
        planner.plan(&[scroll(-5.0, 2, 0)], 0.1);
        assert!(planner.has_pending_scroll());
        let flushed = planner.plan(&[], 10.0);
        assert_eq!(travel(&flushed), -10.0, "both deltas, not just the last");
        assert!(!planner.has_pending_scroll());
    }

    #[test]
    fn a_boundary_or_a_non_scroll_event_flushes_the_residual_first() {
        let mut planner = ScrollCoalescePlanner::new(100.0, true);
        planner.plan(&[scroll(-5.0, 2, 0)], 0.0);
        planner.plan(&[scroll(-5.0, 2, 0)], 0.1);
        let out = planner.plan(&[down(MouseButton::Left)], 0.2);
        assert_eq!(out.len(), 2);
        assert_eq!(
            travel(out.get(..1).unwrap_or_default()),
            -10.0,
            "the residual first"
        );
        assert_eq!(out.get(1), Some(&down(MouseButton::Left)), "then the barrier");
    }

    /// The dual-loss case: both the gesture end and the momentum begin dropped on the wire.
    #[test]
    fn an_on_glass_residual_never_replays_as_momentum() {
        let mut planner = ScrollCoalescePlanner::new(100.0, true);
        planner.plan(&[scroll(-5.0, 2, 0)], 0.0);
        let out = planner.plan(&[scroll(-7.0, 0, 2)], 0.1);
        assert_eq!(out.len(), 1, "the phase change flushed the older domain");
        let flushed = match out.first() {
            Some(&InputEvent::Scroll(scroll, _)) => scroll,
            other => panic!("expected a flushed scroll, got {other:?}"),
        };
        assert_eq!(flushed.scroll_phase, 2, "and kept its own on-glass marker");
        assert_eq!(flushed.dy, -5.0);
    }

    #[test]
    fn a_teardown_drops_the_tail_rather_than_leaking_it_into_the_next_session() {
        let mut planner = ScrollCoalescePlanner::new(100.0, true);
        planner.plan(&[scroll(-5.0, 2, 0)], 0.0);
        planner.plan(&[scroll(-5.0, 2, 0)], 0.1);
        planner.clear_pending();
        assert!(!planner.has_pending_scroll());
        assert!(planner.plan(&[], 1000.0).is_empty());
    }
}
