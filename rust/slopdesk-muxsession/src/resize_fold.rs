//! The PTY size fold: a monotone min over the subscribers that hold a pane (docs/45 §8.3).
//!
//! Every client attached to a pane makes a standing OFFER of how big it wants the shell to be, and
//! the pane runs at the smallest one — monotone, so it settles. An input-keyed "whoever typed last
//! drives" latch has no hysteresis: two clients typing alternately would flap `TIOCSWINSZ` +
//! `SIGWINCH` + a full TUI repaint on every exchange, and one stray byte from a pocket would reflow
//! a 200-column Mac.
//!
//! ## What this module is NOT
//! The write. [`ResizeFold::resolve`] answers what the grid SHOULD be; the caller owns the
//! descriptor, compares against the live `TIOCGWINSZ` and performs the one ioctl. Idempotence is a
//! comparison against the PTY's real size and never against a remembered resolution — a redraw
//! jiggle deliberately leaves the PTY one row short while an app re-layouts, and a "the fold did
//! not change, skip" memo would leave the pane short for the rest of the session.
//!
//! It is also not the timers. The 16 ms debounce and the 750 ms contributor settle are `Task`s in
//! the caller; what lives here is the DECISION to arm one ([`ArmDecision`]) and the generation that
//! decides whether a task already past its sleep still speaks for the newest state.
//!
//! ## The three rules that are easy to get subtly wrong
//! 1. **A pane no VOTER holds is sized by its size-passive members.** "A phone must never crush a
//!    Mac" is about a Mac that is THERE. With an iOS-only setup every subscriber is passive, and
//!    folding them all away leaves the shell at the `openpty` default 80×24 for its whole life. The
//!    fallback keys on the contributing set being EMPTY — not on it having made no offer — so a Mac
//!    that has opened its channel but not yet said how big it is still shuts the phone out.
//! 2. **The settle arms only between two NON-EMPTY sets.** A set going 0→1 or 1→0 has exactly one
//!    possible fold, so there is nothing to coalesce and a fresh pane's first client waits for
//!    nothing.
//! 3. **The ctl override retires on the next CREDITED offer, not on the next apply.** Every `.ack`
//!    flushes the fold and the override's own `SIGWINCH` provokes a repaint the client acks
//!    milliseconds later — retiring on apply would make `slopdesk-ctl resize` inert.

use std::collections::BTreeMap;

/// A subscriber's identity as the mux numbers it. Zero is the channel the session was opened for.
pub type SubscriberId = u64;

/// The subscriber every pane has before any fan-out exists.
pub const PRIMARY_SUBSCRIBER: SubscriberId = 0;

/// One client's offer: a character grid and the pixel metrics of ITS cells.
///
/// The pixels are carried rather than folded — they describe one client's font at one scale, and a
/// min over two clients' cell sizes is a number no display has.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct Grid {
    /// Columns.
    pub cols: u16,
    /// Rows.
    pub rows: u16,
    /// Pixel width of the whole grid, as the offering client measured it.
    pub px: u16,
    /// Pixel height of the whole grid.
    pub py: u16,
}

/// One subscriber's standing offer to the fold.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
struct Contribution {
    /// tmux's `ignore-size`: in the set, folded into nothing while anybody who VOTES holds the
    /// pane.
    size_passive: bool,
    /// `None` until that subscriber's first wire-11 `resize` — a channel that has opened but not
    /// yet said how big it is votes for nothing rather than for 0×0.
    offer: Option<Grid>,
}

/// One contributor as the workspace roster publishes it.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Attachment {
    /// Who.
    pub subscriber: SubscriberId,
    /// Whether the fold ACTUALLY credits this member right now — not the passivity flag alone,
    /// because a phone alone on a pane sizes it.
    pub contributes: bool,
    /// The offered columns, or zero for a member that holds the pane without having said how big.
    pub cols: u16,
    /// The offered rows.
    pub rows: u16,
}

/// What a membership change asks the caller to do.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ArmDecision {
    /// Whether to arm the contributor settle — true only when the voting set moved between two
    /// non-empty states.
    pub arm_settle: bool,
    /// The generation a settle task must quote back, so one already past its sleep can tell whether
    /// a newer change superseded it.
    pub generation: u64,
}

/// What an incoming offer asks the caller to do.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct OfferDecision {
    /// Whether to arm the short resize debounce. False while a contributor settle is outstanding:
    /// the offer simply joins the fold that settle will resolve, and arming here is exactly what
    /// would make a burst of joins `SIGWINCH` the shell once per arrival.
    pub arm_debounce: bool,
    /// The generation the debounce task must quote back.
    pub generation: u64,
}

/// The fold's whole state: who is here, what they offered, and what supersedes them.
///
/// One `NSLock`-guarded object in the caller, so nothing here is `Sync` by itself — the discipline
/// is the caller's, exactly as it was when the state lived in Swift.
#[derive(Clone, Debug, Default)]
pub struct ResizeFold {
    /// Every subscriber's standing offer. Ordered so the pixel fields, which are carried rather
    /// than folded, come from a stable contributor rather than from whichever hash order the map
    /// happened to have.
    contributions: BTreeMap<SubscriberId, Contribution>,
    /// Whether the subscriber this session opened for votes. Resolved HOST-side from the workspace
    /// channel's client kind, never from anything the pane channel itself claims.
    opened_size_passive: bool,
    /// The ctl socket's `resize` verb: an OVERRIDE, not a vote, standing until the next credited
    /// client offer.
    ctl_override: Option<Grid>,
    /// The grid the fold last resolved, for the roster readout. NEVER consulted to decide whether
    /// an apply is needed.
    resolved: Option<Grid>,
    /// Bumped by every scheduled apply; a task past its sleep re-checks it and bails if superseded.
    generation: u64,
    /// Whether a contributor-set settle is outstanding.
    settle_pending: bool,
}

impl ResizeFold {
    /// A fold for a session whose opening subscriber votes (or does not).
    #[must_use]
    pub fn new(opened_size_passive: bool) -> Self {
        Self {
            opened_size_passive,
            ..Self::default()
        }
    }

    /// Registers `subscriber` as a member, or updates its passivity.
    ///
    /// Membership is a STATE-PLANE fact: it changes on an explicit channel open or close and never
    /// on a heartbeat, which is what makes the fold settle instead of flapping with the network. An
    /// existing member KEEPS its standing offer — a reattach swaps the sub-channels while the same
    /// PTY lives on, and forgetting the offer there would snap the pane back to its spawn size
    /// until the returning client happened to send a new one.
    pub fn add_contributor(&mut self, subscriber: SubscriberId, size_passive: bool) -> ArmDecision {
        let before = self.voting_count();
        self.contributions
            .entry(subscriber)
            .and_modify(|existing| existing.size_passive = size_passive)
            .or_insert(Contribution {
                size_passive,
                offer: None,
            });
        self.arm_settle_if_set_changed(before)
    }

    /// Drops `subscriber` from the set. A pane whose set EMPTIES keeps its last size — it does not
    /// snap back to 80×24 (docs/45 §8.3 rule 4).
    pub fn remove_contributor(&mut self, subscriber: SubscriberId) -> ArmDecision {
        // Counted BEFORE the removal rather than reconstructed after it: a size-passive leaver
        // changes the membership without changing the FOLD, and there is nothing to settle when
        // the arithmetic cannot have moved.
        let before = self.voting_count();
        if self.contributions.remove(&subscriber).is_none() {
            return ArmDecision {
                arm_settle: false,
                generation: self.generation,
            };
        }
        self.arm_settle_if_set_changed(before)
    }

    /// Records `subscriber`'s LATEST offer.
    ///
    /// An offer from a subscriber that is not in the set REGISTERS it: the ctl-spawned and
    /// null-sub-channel paths never open a channel, and a resize frame is itself proof that
    /// somebody is holding this pane at a size.
    pub fn note_offer(&mut self, subscriber: SubscriberId, offer: Grid) -> OfferDecision {
        let passive_default = self.opened_size_passive;
        let contribution = self.contributions.entry(subscriber).or_insert(Contribution {
            size_passive: passive_default,
            offer: None,
        });
        contribution.offer = Some(offer);
        let credited = {
            let stored = *contribution;
            // "The next client offer still wins" — and this is that offer. Only a CREDITED one: a
            // size-passive member's offer wins nothing over the fold either, so letting it retire
            // an orchestrator's override would hand a pocketed phone a vote by the back door. The
            // offer is already stored, so a zero voting count reads exactly as "the fold has fallen
            // through to its passive pass".
            credits_offer(stored, self.voting_count() == 0)
        };
        if credited {
            self.ctl_override = None;
        }
        if self.settle_pending {
            return OfferDecision {
                arm_debounce: false,
                generation: self.generation,
            };
        }
        self.generation = self.generation.wrapping_add(1);
        OfferDecision {
            arm_debounce: true,
            generation: self.generation,
        }
    }

    /// Installs the ctl socket's override and takes the generation it applies under.
    ///
    /// The verb is an orchestrator saying "make this pane 132×50". It stands until the next
    /// CREDITED client offer and is superseded by nothing else.
    pub const fn set_ctl_override(&mut self, grid: Grid) -> u64 {
        self.ctl_override = Some(grid);
        self.generation = self.generation.wrapping_add(1);
        self.generation
    }

    /// Resolves the grid, or `None` when nobody is holding this pane at a size.
    ///
    /// `if_generation` is the timer paths' guard: a task already past its sleep must not apply a
    /// fold a newer one superseded. The flush paths (ack, bye, channel close) pass `None` and apply
    /// unconditionally, because they must never strand a size.
    ///
    /// A resolution is REMEMBERED for the roster readout, never for idempotence.
    pub fn resolve(&mut self, if_generation: Option<u64>) -> Option<Grid> {
        if let Some(generation) = if_generation
            && self.generation != generation
        {
            return None;
        }
        let grid = self.ctl_override.or_else(|| self.fold())?;
        self.resolved = Some(grid);
        Some(grid)
    }

    /// Drops every member, for a pane being torn down: nobody holds a dead pane at a size.
    ///
    /// The generation is DELIBERATELY untouched. A debounce or settle task can still be past its
    /// sleep when teardown runs, and resetting the counter would let its stale generation match a
    /// fresh one and apply a fold for a session that is gone.
    pub fn clear_members(&mut self) {
        self.contributions.clear();
        self.ctl_override = None;
        self.settle_pending = false;
    }

    /// Releases the settle latch so ordinary offers arm the short debounce again, guarded by the
    /// generation so a superseded task cannot unlatch a settle a newer set change owns.
    pub const fn clear_settle(&mut self, if_generation: u64) {
        if self.generation == if_generation {
            self.settle_pending = false;
        }
    }

    /// Whether a contributor-set change is still settling.
    #[must_use]
    pub const fn is_settling(&self) -> bool {
        self.settle_pending
    }

    /// The generation the newest scheduled apply carries.
    #[must_use]
    pub const fn generation(&self) -> u64 {
        self.generation
    }

    /// The grid the fold last resolved, for the roster to publish. `None` for a pane nothing has
    /// ever resolved — the caller falls back to the live winsize there, because a ctl-spawned shell
    /// with no contributing subscriber is still a real terminal at a real size and publishing 0×0
    /// would make every client render a letterbox for a pane that is fine.
    #[must_use]
    pub const fn resolved_grid(&self) -> Option<Grid> {
        self.resolved
    }

    /// Every contributor's standing offer in subscriber order, as the roster publishes it.
    ///
    /// A subscriber that has not yet offered reports 0×0, which is honest: it holds the pane but
    /// has not said how big it is.
    #[must_use]
    pub fn attachments(&self) -> Vec<Attachment> {
        let passive_decides = self.voting_count() == 0;
        self.contributions
            .iter()
            .map(|(&subscriber, &contribution)| {
                Attachment {
                    subscriber,
                    contributes: credits_offer(contribution, passive_decides),
                    cols: contribution.offer.map_or(0, |offer| offer.cols),
                    rows: contribution.offer.map_or(0, |offer| offer.rows),
                }
            })
            .collect()
    }

    /// How many members vote.
    #[must_use]
    pub fn voting_count(&self) -> usize {
        self.contributions.values().filter(|c| !c.size_passive).count()
    }

    /// How many members are in the set at all.
    #[must_use]
    pub fn member_count(&self) -> usize {
        self.contributions.len()
    }

    /// `min(cols)` / `min(rows)` over whichever slice of the set votes.
    ///
    /// **A pane no VOTER holds is sized by its size-passive members instead** — see the module
    /// header's rule 1.
    fn fold(&self) -> Option<Grid> {
        let voters = self.voting_count();
        self.contributions
            .values()
            .filter(|contribution| voters == 0 || !contribution.size_passive)
            .filter_map(|contribution| contribution.offer)
            .reduce(|folded, offer| {
                Grid {
                    cols: folded.cols.min(offer.cols),
                    rows: folded.rows.min(offer.rows),
                    // Carried, not folded: they are one client's cell metrics, and the iteration order
                    // is the subscriber order, so they come from a stable contributor.
                    px: folded.px,
                    py: folded.py,
                }
            })
    }

    /// Arms the settle when the voting set moved BETWEEN two non-empty states.
    fn arm_settle_if_set_changed(&mut self, before: usize) -> ArmDecision {
        let after = self.voting_count();
        if before == after || before == 0 || after == 0 {
            return ArmDecision {
                arm_settle: false,
                generation: self.generation,
            };
        }
        self.generation = self.generation.wrapping_add(1);
        self.settle_pending = true;
        ArmDecision {
            arm_settle: true,
            generation: self.generation,
        }
    }
}

/// Whether the fold credits this member's offer right now — the ONE definition of "contributing",
/// shared by the roster readout and the override retirement so the two cannot drift into
/// disagreeing about who counts.
const fn credits_offer(contribution: Contribution, passive_decides: bool) -> bool {
    !contribution.size_passive || passive_decides
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        reason = "a fold this test just fed two offers answering None IS the failure report — softening it \
                  to a default would let a silent fold read as an agreed grid and pass"
    )]

    use super::{Grid, PRIMARY_SUBSCRIBER, ResizeFold};

    fn grid(cols: u16, rows: u16) -> Grid {
        Grid {
            cols,
            rows,
            px: cols * 8,
            py: rows * 16,
        }
    }

    /// The arithmetic docs/45 §8.3 rule 2 names: the smallest offer wins, in both axes
    /// independently.
    #[test]
    fn the_grid_is_the_minimum_of_every_voters_offer() {
        let mut fold = ResizeFold::new(false);
        fold.add_contributor(PRIMARY_SUBSCRIBER, false);
        fold.add_contributor(7, false);
        fold.note_offer(PRIMARY_SUBSCRIBER, grid(120, 50));
        fold.note_offer(7, grid(200, 30));
        let resolved = fold.resolve(None).expect("two offers resolve");
        assert_eq!(resolved.cols, 120);
        assert_eq!(resolved.rows, 30);
    }

    /// Rule 3: a phone in a pocket never crushes a Mac that is THERE.
    #[test]
    fn a_size_passive_member_is_folded_away_while_a_voter_holds_the_pane() {
        let mut fold = ResizeFold::new(false);
        fold.add_contributor(PRIMARY_SUBSCRIBER, false);
        fold.add_contributor(9, true);
        fold.note_offer(PRIMARY_SUBSCRIBER, grid(200, 60));
        fold.note_offer(9, grid(40, 20));
        assert_eq!(fold.resolve(None).expect("the voter sizes it"), grid(200, 60));
    }

    /// Rule 1 of the module header: with no voter at all, the passive members size the pane rather
    /// than leaving the shell at the `openpty` default for its whole life.
    #[test]
    fn a_pane_no_voter_holds_is_sized_by_its_passive_members() {
        let mut fold = ResizeFold::new(true);
        fold.add_contributor(9, true);
        fold.note_offer(9, grid(40, 20));
        assert_eq!(
            fold.resolve(None).expect("the phone sizes its own pane"),
            grid(40, 20)
        );
    }

    /// The fallback keys on the set being EMPTY of voters, not on the voter having offered — a Mac
    /// that has opened its channel but not yet said how big it is still shuts the phone out.
    #[test]
    fn a_silent_voter_still_shuts_the_passive_members_out() {
        let mut fold = ResizeFold::new(false);
        fold.add_contributor(PRIMARY_SUBSCRIBER, false);
        fold.add_contributor(9, true);
        fold.note_offer(9, grid(40, 20));
        assert_eq!(fold.resolve(None), None, "nobody who votes has offered a size");
    }

    /// Rule 4: an emptied set keeps the last size rather than snapping back.
    #[test]
    fn an_emptied_set_resolves_to_nothing_rather_than_to_a_default() {
        let mut fold = ResizeFold::new(false);
        fold.add_contributor(PRIMARY_SUBSCRIBER, false);
        fold.note_offer(PRIMARY_SUBSCRIBER, grid(100, 40));
        fold.remove_contributor(PRIMARY_SUBSCRIBER);
        assert_eq!(fold.resolve(None), None, "no offer left to resolve");
    }

    /// A reattach swaps the sub-channels while the PTY lives on: re-adding a member must not forget
    /// what it offered.
    #[test]
    fn re_adding_a_member_keeps_its_standing_offer() {
        let mut fold = ResizeFold::new(false);
        fold.add_contributor(PRIMARY_SUBSCRIBER, false);
        fold.note_offer(PRIMARY_SUBSCRIBER, grid(100, 40));
        fold.add_contributor(PRIMARY_SUBSCRIBER, false);
        assert_eq!(fold.resolve(None), Some(grid(100, 40)));
    }

    /// Rule 6: the ctl verb stands until the next CREDITED client offer.
    #[test]
    fn the_ctl_override_stands_until_a_crediting_offer_retires_it() {
        let mut fold = ResizeFold::new(false);
        fold.add_contributor(PRIMARY_SUBSCRIBER, false);
        fold.note_offer(PRIMARY_SUBSCRIBER, grid(100, 40));
        fold.set_ctl_override(grid(132, 50));
        assert_eq!(
            fold.resolve(None),
            Some(grid(132, 50)),
            "the override wins the resolve"
        );
        fold.note_offer(PRIMARY_SUBSCRIBER, grid(90, 30));
        assert_eq!(
            fold.resolve(None),
            Some(grid(90, 30)),
            "the next client offer takes it back"
        );
    }

    /// A pocketed phone must not retire an orchestrator's override by the back door.
    #[test]
    fn a_folded_away_members_offer_does_not_retire_the_override() {
        let mut fold = ResizeFold::new(false);
        fold.add_contributor(PRIMARY_SUBSCRIBER, false);
        fold.add_contributor(9, true);
        fold.note_offer(PRIMARY_SUBSCRIBER, grid(100, 40));
        fold.set_ctl_override(grid(132, 50));
        fold.note_offer(9, grid(40, 20));
        assert_eq!(fold.resolve(None), Some(grid(132, 50)));
    }

    /// …but a phone ALONE on a pane is the next client offer, which is what once locked a lone
    /// phone out of its own pane for good after a single `slopdesk-ctl resize`.
    #[test]
    fn a_lone_passive_members_offer_does_retire_the_override() {
        let mut fold = ResizeFold::new(true);
        fold.add_contributor(9, true);
        fold.note_offer(9, grid(40, 20));
        fold.set_ctl_override(grid(132, 50));
        fold.note_offer(9, grid(44, 22));
        assert_eq!(fold.resolve(None), Some(grid(44, 22)));
    }

    /// Rule 2: the settle arms between two non-empty sets and nowhere else.
    #[test]
    fn the_settle_arms_only_between_two_non_empty_voting_sets() {
        let mut fold = ResizeFold::new(false);
        assert!(
            !fold.add_contributor(PRIMARY_SUBSCRIBER, false).arm_settle,
            "0 -> 1 is one fold"
        );
        assert!(
            fold.add_contributor(7, false).arm_settle,
            "1 -> 2 has two offers to coalesce"
        );
        assert!(
            fold.remove_contributor(7).arm_settle,
            "2 -> 1 changes the arithmetic"
        );
        assert!(
            !fold.remove_contributor(PRIMARY_SUBSCRIBER).arm_settle,
            "1 -> 0 is nothing to fold"
        );
    }

    /// A size-passive join changes the membership without changing the fold.
    #[test]
    fn a_passive_join_does_not_arm_the_settle() {
        let mut fold = ResizeFold::new(false);
        fold.add_contributor(PRIMARY_SUBSCRIBER, false);
        assert!(!fold.add_contributor(9, true).arm_settle);
        assert!(!fold.remove_contributor(9).arm_settle);
    }

    /// An offer arriving mid-settle joins the fold instead of arming the short debounce — arming it
    /// there is what would `SIGWINCH` the shell once per arrival in a burst of joins.
    #[test]
    fn an_offer_during_a_settle_does_not_arm_the_debounce() {
        let mut fold = ResizeFold::new(false);
        fold.add_contributor(PRIMARY_SUBSCRIBER, false);
        let armed = fold.add_contributor(7, false);
        assert!(armed.arm_settle);
        let decision = fold.note_offer(7, grid(80, 24));
        assert!(!decision.arm_debounce);
        assert_eq!(
            decision.generation, armed.generation,
            "the settle still owns the generation"
        );
        fold.clear_settle(armed.generation);
        assert!(
            fold.note_offer(7, grid(80, 25)).arm_debounce,
            "the latch released"
        );
    }

    /// The generation is what makes the LATEST size win when a task is already past its sleep.
    #[test]
    fn a_superseded_generation_resolves_to_nothing() {
        let mut fold = ResizeFold::new(false);
        fold.add_contributor(PRIMARY_SUBSCRIBER, false);
        let first = fold.note_offer(PRIMARY_SUBSCRIBER, grid(100, 40));
        let second = fold.note_offer(PRIMARY_SUBSCRIBER, grid(90, 30));
        assert_eq!(fold.resolve(Some(first.generation)), None, "superseded");
        assert_eq!(fold.resolve(Some(second.generation)), Some(grid(90, 30)));
        assert_eq!(
            fold.resolve(None),
            Some(grid(90, 30)),
            "a flush applies unconditionally"
        );
    }

    /// A superseded settle task must not unlatch a settle a newer set change owns.
    #[test]
    fn clearing_a_stale_settle_leaves_the_latch_alone() {
        let mut fold = ResizeFold::new(false);
        fold.add_contributor(PRIMARY_SUBSCRIBER, false);
        let stale = fold.add_contributor(7, false);
        let fresh = fold.add_contributor(8, false);
        fold.clear_settle(stale.generation);
        assert!(fold.is_settling(), "the newer set change still owns the latch");
        fold.clear_settle(fresh.generation);
        assert!(!fold.is_settling());
    }

    /// The roster publishes what the fold CREDITS, not the passivity flag alone.
    #[test]
    fn the_roster_credits_a_lone_phone_and_a_held_pane_alike() {
        let mut fold = ResizeFold::new(true);
        fold.add_contributor(9, true);
        fold.note_offer(9, grid(40, 20));
        let alone = fold.attachments();
        assert_eq!(alone.len(), 1);
        assert!(
            alone.first().is_some_and(|a| a.contributes),
            "a phone alone sizes its pane"
        );

        fold.add_contributor(PRIMARY_SUBSCRIBER, false);
        let held = fold.attachments();
        assert_eq!(
            held.first().map(|a| a.subscriber),
            Some(PRIMARY_SUBSCRIBER),
            "subscriber order"
        );
        assert!(
            held.first().is_some_and(|a| a.contributes && a.cols == 0),
            "here, silent, voting"
        );
        assert!(
            held.last().is_some_and(|a| !a.contributes),
            "the phone is folded away again"
        );
    }

    /// The pixel metrics are carried from a stable contributor rather than folded into a number no
    /// display has.
    #[test]
    fn the_pixel_metrics_come_from_the_lowest_subscriber_rather_than_a_minimum() {
        let mut fold = ResizeFold::new(false);
        fold.add_contributor(3, false);
        fold.add_contributor(4, false);
        fold.note_offer(3, Grid {
            cols: 100,
            rows: 40,
            px: 1600,
            py: 900,
        });
        fold.note_offer(4, Grid {
            cols: 80,
            rows: 50,
            px: 640,
            py: 480,
        });
        let resolved = fold.resolve(None).expect("both offered");
        assert_eq!((resolved.cols, resolved.rows), (80, 40));
        assert_eq!((resolved.px, resolved.py), (1600, 900));
    }

    /// An offer from a stranger registers it: the ctl-spawned path never opens a channel, and a
    /// resize frame is proof somebody holds the pane.
    #[test]
    fn an_offer_from_an_unregistered_subscriber_registers_it() {
        let mut fold = ResizeFold::new(false);
        fold.note_offer(42, grid(100, 40));
        assert_eq!(fold.member_count(), 1);
        assert_eq!(fold.resolve(None), Some(grid(100, 40)));
    }

    /// Teardown drops the members without rewinding the generation a live task may still quote.
    #[test]
    fn clearing_the_members_leaves_the_generation_where_it_was() {
        let mut fold = ResizeFold::new(false);
        fold.add_contributor(PRIMARY_SUBSCRIBER, false);
        let live = fold.note_offer(PRIMARY_SUBSCRIBER, grid(100, 40));
        fold.set_ctl_override(grid(132, 50));
        fold.clear_members();
        assert_eq!(fold.member_count(), 0);
        assert_eq!(fold.resolve(None), None, "nobody holds a dead pane at a size");
        assert!(
            fold.generation() > live.generation,
            "a stale task cannot match a rewound counter"
        );
    }

    /// Removing somebody who was never here is not a set change.
    #[test]
    fn removing_a_stranger_arms_nothing() {
        let mut fold = ResizeFold::new(false);
        fold.add_contributor(PRIMARY_SUBSCRIBER, false);
        let before = fold.generation();
        let decision = fold.remove_contributor(77);
        assert!(!decision.arm_settle);
        assert_eq!(decision.generation, before);
    }
}
