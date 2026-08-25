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
/// kills a live detached session. The resource bound in that mode is per-pane, and SlopDesk's is
/// the stricter of the two.
///
/// The victim is chosen AFTER the displacement, because the displaced entry is already leaving.
#[must_use]
pub fn insert_verdict(
    stamps: &[f64],
    occupant: Option<Occupant>,
    cap: Option<usize>,
) -> InsertVerdict {
    let displaced = match occupant {
        Some(held) if held.same_session => {
            return InsertVerdict {
                victim: None,
                idempotent: true,
                displace: false,
            };
        }
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

#[cfg(test)]
mod tests {
    use super::{InsertVerdict, Occupant, detached_order, insert_verdict};

    #[test]
    fn an_unbounded_store_never_evicts() {
        let stamps = [10.0, 20.0, 30.0];
        assert_eq!(
            insert_verdict(&stamps, None, None),
            InsertVerdict {
                victim: None,
                idempotent: false,
                displace: false,
            }
        );
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
}
