//! What the detached-session store KEEPS, and what it lets go of to make room.
//!
//! A client that disconnects with `SLOPDESK_DETACH_ENABLED` on leaves its session PARKED rather
//! than shut down: it lives until the client returns and claims it, until a TTL fires, or until
//! hostd stops. The store around that is a lock, a dictionary and a `Task` per entry, none of which
//! is here. What is here is the two questions the lock is held for.
//!
//! ## No identity crosses
//! A session is a `UUID` and a class instance, and neither is a thing this crate can hold. The
//! caller answers both questions it alone can answer — *is this the same OBJECT arriving twice*
//! (`===`, not `==`) and *where in my list does this id already sit* — and the answers come back as
//! POSITIONS into the list it still holds. That is `store_shape`'s convention, one target over.
//!
//! ## Why `detachedAt` crosses as a raw `f64`
//! It is Foundation's `timeIntervalSinceReferenceDate` unchanged, and nothing here does arithmetic
//! on it: the two rules only ORDER stamps, through `f64::total_cmp`, which is a total order over
//! every bit pattern including the ones `<` refuses to rank. Converting to an integer would be
//! arithmetic on a float in a tree that pins float behaviour, to answer a question that never
//! needed the magnitude.
//!
//! ## Taking an entry OUT, which two callers race for
//!
//! [`take`] is the other half of the lock. Two reconnects can present the same `sessionID` at once,
//! and a third party — the armed TTL, the daemon stop, the shell's own exit — can be removing the
//! entry underneath both. Exactly one of them may get the session, so the store hands the ANSWER
//! back rather than the entry: did THIS call win.
//!
//! The loser is not merely told "no". It is told nothing happened, which is what makes the
//! stale-teardown case safe: a detached session's exit closure fires after a reattach already took
//! the entry, and if it read that as its own success it would release the journal writer and the
//! hook-sink key that a same-UUID SUCCESSOR is already using — the live pane keeps running with its
//! journaling and its agent-status routing silently switched off.
//!
//! ## Why a dead child is its own answer and not "not found"
//!
//! A parked session whose shell already exited is taken out and shut down, and the caller is told
//! [`TakeVerdict::reap_dead_child`] rather than being told the store was empty. The difference is
//! an obligation: the winning caller has just assumed a teardown the session's own exit closure
//! stood down from, so before it spawns the fresh shell for the same id it still owes the final
//! agent-status `.none` (the prevent-sleep balance is strict) and the drop of the hook-sink key.
//! Folded into "not found", both would be skipped and neither would leave a trace.
//!
//! This reap deliberately does NOT go through the store's eviction hook. That hook re-takes the
//! server's own lock, and this path already holds it; and the fresh shell taking the id over reuses
//! the journal writer the hook would have released.
//!
//! ## The TIMER is a decision; the `Task` around it is not
//!
//! [`ttl_on_insert`] is the arm/leave choice, and each arm names a failure. Arming on an idempotent
//! re-park leaves the original entry's timer running beside a second one, and the older of the two
//! later evicts whatever live entry holds the id. Not cancelling a departing entry's timer is the
//! same failure from the other end. What is NOT here is the sleep, the cancellation token, or the
//! eviction it eventually calls — those are a `Task`, and a rule that owned one could not be tested
//! without waiting for it.

/// The entry already filed under the incoming session's id.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Occupant {
    /// Its position in the stamps handed in.
    pub position: usize,
    /// Whether it is the SAME session object arriving twice — `===`, which only the caller can
    /// ask. A re-park of an object the store already holds is not a new entry.
    pub same_session: bool,
}

/// What one insert does to the store.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct InsertVerdict {
    /// The entry to evict for room, as a position into the stamps handed in. The caller kills it
    /// and fires its eviction hook; this is the OPT-IN cap's only effect.
    pub victim: Option<usize>,
    /// The store already holds this very session — keep the ORIGINAL entry and do nothing else.
    ///
    /// Overwriting it would leak the first entry's TTL task un-cancelled, and that stale timer
    /// would later evict whatever live entry holds the id. The failed-rebind recovery and the
    /// link-down handler can both park one session on a mid-reattach drop, so this arm is reached.
    pub idempotent: bool,
    /// A DIFFERENT session holds this id: newest wins, and the displaced entry's TTL task must be
    /// cancelled before it evicts the new one.
    ///
    /// The displaced session is the caller's to reap ONLY when nobody holds it — a session with
    /// subscribers is live and reachable, and killing it here would take down a client's running
    /// agent to make room for a store entry. What keeps this arm rare is the join: a live id routes
    /// to the session that already exists, so two connections on one pane share one object and park
    /// it once, when the last subscriber leaves.
    pub displace: bool,
}

/// The insert rule, over the `detachedAt` stamps of every entry the store currently holds.
///
/// `cap` is the OPT-IN `SLOPDESK_DETACH_MAX_SESSIONS` bound, and `None` is UNBOUNDED — the default,
/// and the tmux/zellij semantics: neither imposes a session count limit and neither ever silently
/// kills a live detached session. The resource bound in that mode is per-pane, and `SlopDesk`'s is
/// the stricter of the two.
///
/// The victim is chosen AFTER the displacement, because the displaced entry is already leaving.
#[must_use]
pub fn insert_verdict(stamps: &[f64], occupant: Option<Occupant>, cap: Option<usize>) -> InsertVerdict {
    let displaced = match occupant {
        Some(held) if held.same_session => {
            return InsertVerdict {
                victim: None,
                idempotent: true,
                displace: false,
            };
        },
        Some(held) => Some(held.position),
        None => None,
    };
    let displace = displaced.is_some();
    let Some(limit) = cap else {
        return InsertVerdict {
            victim: None,
            idempotent: false,
            displace,
        };
    };
    let remaining = stamps.len().saturating_sub(usize::from(displace));
    if remaining < limit {
        return InsertVerdict {
            victim: None,
            idempotent: false,
            displace,
        };
    }
    InsertVerdict {
        victim: oldest(stamps, displaced),
        idempotent: false,
        displace,
    }
}

/// The position of the OLDEST stamp, skipping `skip`. Ties go to the earliest position, which is
/// what `min(by:)` answered over a dictionary's arbitrary order and is now not arbitrary.
fn oldest(stamps: &[f64], skip: Option<usize>) -> Option<usize> {
    stamps
        .iter()
        .enumerate()
        .filter(|(position, _)| Some(*position) != skip)
        .min_by(|left, right| left.1.total_cmp(right.1))
        .map(|(position, _)| position)
}

/// Every stored entry in `detachedAt` order, as positions into the stamps handed in.
///
/// A pane whose client quit is ALIVE — that is the entire point of the store — but it lived outside
/// every enumeration the product had, so `slopdesk-ctl list-panes` reported nothing for exactly the
/// panes a returning user cares about. The order is by stamp so the listing is stable rather than
/// dictionary-ordered, and ties keep the caller's own order rather than resolving arbitrarily.
#[must_use]
pub fn detached_order(stamps: &[f64]) -> Vec<usize> {
    let mut order: Vec<usize> = (0..stamps.len()).collect();
    order.sort_by(|left, right| {
        let first = stamps.get(*left).copied().unwrap_or(f64::INFINITY);
        let second = stamps.get(*right).copied().unwrap_or(f64::INFINITY);
        first.total_cmp(&second)
    });
    order
}

/// What one transition does to an entry's eviction timer.
///
/// Three arms rather than a bool, because "there is no timer to touch" and "keep the timer that is
/// already running" read the same at a call site and mean opposite things the moment one of them
/// stops being true.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TtlChoice {
    /// Arm a fresh eviction timer over the configured TTL.
    Arm,
    /// Cancel the timer this entry carries. Every DEPARTURE takes this arm: an armed timer outlives
    /// the entry it was armed for and then evicts by id, which is a live successor's id by then.
    Cancel,
    /// Touch no timer. Two ways in, and they are not the same state — see [`ttl_on_insert`].
    LeaveAlone,
}

impl TtlChoice {
    /// The byte this crosses the FFI door under.
    #[must_use]
    pub const fn code(self) -> u8 {
        match self {
            Self::Arm => 0,
            Self::Cancel => 1,
            Self::LeaveAlone => 2,
        }
    }
}

/// What one attempt to TAKE an entry out of the store concluded.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct TakeVerdict {
    /// THIS call removed the entry — it won the teardown, and owns whatever the entry's own
    /// cleanup would have done. `false` means somebody else already took it and this caller must
    /// stand down rather than release resources a successor holds.
    pub won: bool,
    /// What to do about the entry's timer.
    pub ttl: TtlChoice,
    /// The shell had already exited: shut the parked session down, and report this apart from "not
    /// found" so the winner discharges the teardown the session's exit closure stood down from.
    pub reap_dead_child: bool,
}

/// The take rule, for every caller that removes an entry by id.
///
/// `present` is whether the id was still filed when the lock was taken — the only fact that decides
/// who won, and one only the near side can establish, because the removal and the question are the
/// same dictionary operation.
///
/// `child_exited` is the near side's `isChildExited()`, which is a `waitpid` that has already
/// reaped: a shell that has an exit code. An UNSPAWNED pane answers `false` — it has no child to
/// have exited — and that is the honest answer, not an oversight.
///
/// The caller that removes an entry BECAUSE the shell exited passes `false`: its `onExit` has
/// already fired, so there is nothing left to discover and nothing left to reap, and asking would
/// only invite a second teardown of a process that is already gone.
#[must_use]
pub const fn take(present: bool, child_exited: bool) -> TakeVerdict {
    if !present {
        return TakeVerdict {
            won: false,
            ttl: TtlChoice::LeaveAlone,
            reap_dead_child: false,
        };
    }
    TakeVerdict {
        won: true,
        ttl: TtlChoice::Cancel,
        reap_dead_child: child_exited,
    }
}

/// The timer choice for an entry going IN, given the insert's own verdict.
///
/// `idempotent` is [`InsertVerdict::idempotent`] — the same session re-parked, whose ORIGINAL entry
/// is being kept along with the timer already armed on it. Arming a second one there is the failure
/// the idempotent arm exists to prevent, and it is not a leak so much as a delayed mis-eviction:
/// the two timers evict by ID, so the first to fire kills whatever entry holds that id by then.
///
/// `has_ttl` is whether a TTL is configured at all. Unset — `SLOPDESK_DETACH_TTL_SECS` absent or
/// `0` — means the parked session lives INDEFINITELY, which is the default and the tmux/zellij
/// semantics: the resource bound in that mode is the opt-in session cap, never a clock.
///
/// So [`TtlChoice::LeaveAlone`] comes back for two different reasons — a timer that is already
/// running, and a timer that was never asked for — and the caller does the same nothing either way.
/// They are one arm because the ACT is one act; the doc is where they stay apart.
#[must_use]
pub const fn ttl_on_insert(idempotent: bool, has_ttl: bool) -> TtlChoice {
    if idempotent || !has_ttl {
        TtlChoice::LeaveAlone
    } else {
        TtlChoice::Arm
    }
}

#[cfg(test)]
mod tests {
    use super::{InsertVerdict, Occupant, TtlChoice, detached_order, insert_verdict, take, ttl_on_insert};

    #[test]
    fn an_unbounded_store_never_evicts() {
        let stamps = [10.0, 20.0, 30.0];
        assert_eq!(insert_verdict(&stamps, None, None), InsertVerdict {
            victim: None,
            idempotent: false,
            displace: false,
        });
    }

    #[test]
    fn the_same_session_arriving_twice_changes_nothing() {
        let stamps = [10.0, 20.0];
        let verdict = insert_verdict(
            &stamps,
            Some(Occupant {
                position: 1,
                same_session: true,
            }),
            Some(1),
        );
        assert_eq!(
            verdict,
            InsertVerdict {
                victim: None,
                idempotent: true,
                displace: false,
            },
            "an idempotent re-park never evicts, however full the store is",
        );
    }

    #[test]
    fn a_different_session_on_the_same_id_displaces_the_old_one() {
        let stamps = [10.0, 20.0];
        let verdict = insert_verdict(
            &stamps,
            Some(Occupant {
                position: 0,
                same_session: false,
            }),
            None,
        );
        assert!(verdict.displace);
        assert!(!verdict.idempotent);
        assert_eq!(verdict.victim, None);
    }

    #[test]
    fn a_full_store_evicts_the_oldest() {
        let stamps = [30.0, 10.0, 20.0];
        assert_eq!(insert_verdict(&stamps, None, Some(3)).victim, Some(1));
    }

    #[test]
    fn room_below_the_cap_evicts_nobody() {
        let stamps = [30.0, 10.0];
        assert_eq!(insert_verdict(&stamps, None, Some(3)).victim, None);
    }

    #[test]
    fn the_displaced_entry_is_never_also_the_overflow_victim() {
        // Position 0 is both the oldest AND the entry being displaced. It is already leaving, so
        // the cap has to take the next-oldest or it would count one departure twice.
        let stamps = [10.0, 20.0, 30.0];
        let verdict = insert_verdict(
            &stamps,
            Some(Occupant {
                position: 0,
                same_session: false,
            }),
            Some(2),
        );
        assert!(verdict.displace);
        assert_eq!(verdict.victim, Some(1));
    }

    #[test]
    fn a_displacement_can_make_the_cap_stop_biting() {
        let stamps = [10.0, 20.0];
        let verdict = insert_verdict(
            &stamps,
            Some(Occupant {
                position: 1,
                same_session: false,
            }),
            Some(2),
        );
        assert!(verdict.displace);
        assert_eq!(verdict.victim, None, "one leaving already made the room");
    }

    #[test]
    fn a_cap_of_zero_with_nothing_stored_has_nothing_to_take() {
        assert_eq!(insert_verdict(&[], None, Some(0)).victim, None);
    }

    #[test]
    fn equal_stamps_evict_the_earliest_position() {
        let stamps = [10.0, 10.0, 10.0];
        assert_eq!(insert_verdict(&stamps, None, Some(3)).victim, Some(0));
    }

    #[test]
    fn the_listing_is_oldest_first() {
        assert_eq!(detached_order(&[30.0, 10.0, 20.0]), vec![1, 2, 0]);
        assert_eq!(detached_order(&[]), Vec::<usize>::new());
    }

    #[test]
    fn equal_stamps_keep_the_callers_order() {
        assert_eq!(detached_order(&[5.0, 1.0, 5.0, 1.0]), vec![1, 3, 0, 2]);
    }

    // ── Taking an entry out ───────────────────────────────────────────────────────────────

    /// Of two reconnects presenting one `sessionID`, exactly ONE gets the session. The loser is
    /// told nothing happened, and falls through to the fresh-shell path where the live-id guard
    /// refuses the duplicate.
    #[test]
    fn an_absent_entry_means_this_caller_did_not_win_and_has_no_timer_to_cancel() {
        let verdict = take(false, false);
        assert!(!verdict.won);
        assert_eq!(verdict.ttl, TtlChoice::LeaveAlone);
        assert!(!verdict.reap_dead_child);
    }

    /// Whether the child had exited cannot change who won — the id was gone before the question
    /// was asked. Pinned because a caller reading `reap_dead_child` without `won` would tear down
    /// a session another caller is holding.
    #[test]
    fn a_dead_child_on_an_absent_entry_still_wins_nothing() {
        assert_eq!(take(false, true), take(false, false));
    }

    /// The ordinary reattach: the entry is taken, its timer cancelled in the same critical section
    /// so an armed eviction can no longer find it, and the live session handed over.
    #[test]
    fn a_live_entry_is_claimed_and_its_timer_cancelled_in_the_same_breath() {
        let verdict = take(true, false);
        assert!(verdict.won);
        assert_eq!(
            verdict.ttl,
            TtlChoice::Cancel,
            "an armed eviction that survives the claim kills the PTY out from under the rebind",
        );
        assert!(!verdict.reap_dead_child);
    }

    /// The interesting outcome. The client came back to a shell that had already exited: it must
    /// get a FRESH one rather than hang on a dead one, and the winner still owes the teardown the
    /// session's own exit closure stood down from.
    #[test]
    fn a_dead_child_is_reaped_and_reported_apart_from_not_found() {
        let dead = take(true, true);
        assert!(dead.won);
        assert!(dead.reap_dead_child);
        assert_eq!(dead.ttl, TtlChoice::Cancel);
        assert_ne!(
            dead,
            take(false, true),
            "reaped-dead-child and not-found must never read the same: one owes a teardown and the other \
             owes nothing",
        );
        assert_ne!(
            dead,
            take(true, false),
            "and it must not read as an ordinary claim either — the caller would hand a client a session \
             whose shell is gone",
        );
    }

    /// The clean-exit remover asks the same rule with `child_exited: false`, and reads only
    /// `won` — its whole question is whether it is the one that has to stand down.
    #[test]
    fn the_clean_exit_remover_reads_the_same_verdict_as_a_latch() {
        assert!(
            take(true, false).won,
            "this call removed the entry: finish the teardown"
        );
        assert!(
            !take(false, false).won,
            "somebody already took it; releasing the journal writer now would cut a same-UUID successor's \
             journaling and its agent-status routing",
        );
    }

    // ── The timer ─────────────────────────────────────────────────────────────────────────

    #[test]
    fn a_fresh_insert_with_a_ttl_arms_one_timer() {
        assert_eq!(ttl_on_insert(false, true), TtlChoice::Arm);
    }

    /// The default, and the tmux/zellij semantics: a parked session lives until it is claimed or
    /// the daemon lets it go. No clock is involved, so there is nothing to arm.
    #[test]
    fn an_insert_with_no_ttl_configured_arms_nothing() {
        assert_eq!(ttl_on_insert(false, false), TtlChoice::LeaveAlone);
    }

    /// The failed-rebind recovery and the link-down handler can both park ONE session on a
    /// mid-reattach drop. A second timer beside the first evicts by id, so whichever fires first
    /// kills whatever entry holds that id by then — which is a live one.
    #[test]
    fn an_idempotent_re_park_never_arms_a_second_timer() {
        assert_eq!(ttl_on_insert(true, true), TtlChoice::LeaveAlone);
        assert_eq!(ttl_on_insert(true, false), TtlChoice::LeaveAlone);
    }

    /// The three arms cross as distinct bytes; a collision would make a departure read as an
    /// arming on the far side.
    #[test]
    fn each_timer_choice_crosses_as_its_own_byte() {
        assert_eq!(TtlChoice::Arm.code(), 0);
        assert_eq!(TtlChoice::Cancel.code(), 1);
        assert_eq!(TtlChoice::LeaveAlone.code(), 2);
    }
}
