//! Where an inbound `channelOpen` GOES, and the three numbers a pane's arrival turns on.
//!
//! ## The decision this replaces
//! hostd's `spawnMuxChannel` is one critical section with seven exits: a workspace channel routes
//! away before the PTY reasoning starts, an unknown class is declined, a shutting-down host
//! refuses, a duplicate open on a key that already has a session re-acks, a session id somebody
//! else is already watching JOINS that one object, an id the detached store may still hold is
//! CLAIMED, and everything left forks a fresh shell. Which of the seven a given open takes was
//! decided by five booleans read under `lock`, in an order that was only ever a comment — and the
//! comment is load-bearing: routing a live id past the JOIN and into the spawn path rotates the
//! incumbent's journal writer out from under it, and its transcript stops mid-session.
//!
//! That order is a Rust test here instead. What crosses is FACTS — a class byte, whether the host
//! is stopping, whether an incumbent holds this id and under which key, whether the id is real,
//! whether a detached store exists — and what comes back is one of seven verdicts. No identity
//! crosses: hostd resolves each verdict against the objects it already holds.
//!
//! ## Why the incumbent is one value and not two flags
//! `already_live` and `live_elsewhere` were two separate booleans that could never both be true —
//! the second was computed only when the first was false — so the pair had a fourth state that
//! meant nothing and a route that would have been undefined for it. [`Incumbent`] has exactly the
//! three states the question has, and the route for each is total.
//!
//! ## What deliberately did NOT come here
//! - **The lock, and everything inside it.** hostd still takes `lock`, still reads its maps, still
//!   registers the joining key and still calls `store.claim` — the claim MUTATES a Swift store and
//!   cancels a Swift TTL task. What this module answers is whether to attempt it, and [`settle`]
//!   turns its outcome into the next action.
//! - **The objects.** A `MuxChannelSession` is an actor with a PTY; the verdict names a ROUTE, and
//!   hostd looks up the session.
//! - **The class vocabulary.** [`MuxChannelClass::from_byte`] owns which bytes this build routes; a
//!   class this crate restated would be the fourth copy of a wire fact, which is the drift the
//!   one-implementation rule exists for.

use slopdesk_wire::mux::MuxChannelClass;

/// Who, if anyone, is already holding the session id this open presents.
///
/// Three states, and the middle one is the whole reason the type exists: a pane is SHARED, never
/// handed over and never duplicated, so an id that is live under a different composite key is a
/// join rather than a claim or a spawn.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
#[repr(u8)]
pub enum Incumbent {
    /// Nothing live answers to this id. The open is free to claim or to spawn.
    #[default]
    None = 0,
    /// A session is already registered under THIS composite key — a duplicate or retransmitted
    /// `channelOpen`. Forking a second PTY here would orphan the first one's master and its reaper.
    ThisKey = 1,
    /// The same id is live under a DIFFERENT composite key: a second window or device presenting
    /// an id somebody is still watching.
    OtherKey = 2,
}

/// What hostd does with one `channelOpen`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum Route {
    /// Not a pane at all — the workspace document rides an ordinary open with its own class byte.
    /// Routed away FIRST, so it never touches the one-shell-per-id reasoning (docs/45 §5.1).
    Workspace = 1,
    /// A class this build serves nobody under. Declined rather than guessed at: falling through
    /// would hand a peer one version ahead a login shell it never asked for.
    Decline = 2,
    /// The host is stopping. Refused, so no PTY is forked that would outlive the daemon.
    RefuseStopping = 3,
    /// A session already answers to this key. Re-ack idempotently and touch nothing.
    ReAck = 4,
    /// The id is live elsewhere — add this client to that session's roster.
    Join = 5,
    /// The id may be parked in the detached store. Attempt the exclusive claim, then [`settle`].
    Claim = 6,
    /// Nobody holds the id and nothing can be claimed for it — fork a shell.
    SpawnFresh = 7,
}

/// Everything the route depends on, read under hostd's one critical section.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct OpenFacts {
    /// The open's raw `channel_class` byte, unvalidated on purpose.
    pub channel_class: u8,
    /// Who already holds this session id.
    pub incumbent: Incumbent,
    /// Whether `stop()` has already begun draining.
    pub stopping: bool,
    /// Whether the id is a real one rather than the zero sentinel a first-connect preamble carries.
    pub real_session_id: bool,
    /// Whether a detached store exists at all — detach is opt-in, and without it there is nothing
    /// to claim.
    pub detached_store: bool,
}

/// Routes one `channelOpen`.
///
/// The order is the invariant. Class first (a workspace channel and an unserved class must never
/// reach the PTY reasoning), then the host's own condition, then the incumbent, then the store.
/// An [`Incumbent::OtherKey`] carrying the zero sentinel cannot arise — the sentinel is not
/// looked up — and falls through to a spawn rather than joining an id that is not an id.
#[must_use]
pub const fn route(facts: OpenFacts) -> Route {
    match MuxChannelClass::from_byte(facts.channel_class) {
        Some(MuxChannelClass::Workspace) => return Route::Workspace,
        Some(MuxChannelClass::Pane) => {},
        None => return Route::Decline,
    }
    if facts.stopping {
        return Route::RefuseStopping;
    }
    match facts.incumbent {
        Incumbent::ThisKey => return Route::ReAck,
        Incumbent::OtherKey if facts.real_session_id => return Route::Join,
        Incumbent::OtherKey | Incumbent::None => {},
    }
    if facts.real_session_id && facts.detached_store {
        Route::Claim
    } else {
        Route::SpawnFresh
    }
}

/// What the detached store said when [`Route::Claim`] was attempted.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum Claim {
    /// The store held a live detached session and this open took it exclusively.
    Claimed = 1,
    /// The store held an entry whose child had already exited; the lookup evicted it.
    ReapedDeadChild = 2,
    /// The store held nothing for this id.
    NotFound = 3,
}

/// What hostd does once the claim has answered.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum Settled {
    /// Rebind the claimed session to the new sub-channels.
    Reattach = 1,
    /// Fan the dead session's final agent teardown and drop its hook sink, THEN fork a fresh shell
    /// under the same id. The journal writer is deliberately not released — the same-id spawn
    /// rotates it, keeping the transcript file continuous.
    ReapThenSpawn = 2,
    /// Nothing was there. Fork a shell.
    SpawnFresh = 3,
}

/// Turns a claim outcome into the next action.
#[must_use]
pub const fn settle(outcome: Claim) -> Settled {
    match outcome {
        Claim::Claimed => Settled::Reattach,
        Claim::ReapedDeadChild => Settled::ReapThenSpawn,
        Claim::NotFound => Settled::SpawnFresh,
    }
}

/// The sentinel `PaneOutputStream` reads as "subscribe at the live edge, hand me no history".
pub const FROM_NOW_ON: u64 = u64::MAX;

/// The host-authoritative answer to "where does this returning client pick up".
///
/// A verdict that exceeds what the session can actually number is worse than useless: it tells a
/// warm client to keep dedup marks above every seq the session will ever assign, so the restored
/// transcript and all live output arrive below the mark and are dropped — a terminal that renders
/// nothing while keystrokes still reach the shell, reached by the very path that exists to bring a
/// pane back. An ADOPTED pane is exactly that case: a new session object around an old shell, whose
/// replay buffer starts at zero.
///
/// The zero this produces is precisely the "reset your marks" the client already understands
/// (docs/20 §8.2 — only `resumeFromSeq == 0` resets).
#[must_use]
pub const fn resume_from(last_received_seq: i64, highest_assigned_seq: i64) -> i64 {
    if last_received_seq < highest_assigned_seq {
        last_received_seq
    } else {
        highest_assigned_seq
    }
}

/// How to make the reattached shell repaint.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum Redraw {
    /// A plain `SIGWINCH` at the same size. Enough whenever the client's grid is trustworthy.
    Nudge = 1,
    /// Shrink one row, hold, restore. A COLD client on a transform-collapsed replay holds a partial
    /// frame, and a differential renderer ignores a same-size `SIGWINCH` for rows it believes are
    /// already painted — so the collapsed rows stay blank forever unless the size REALLY changes.
    Jiggle = 2,
}

/// Which repaint a reattach earns.
///
/// A rendered-snapshot replay needs no jiggle whatever the client's warmth: every row the app
/// believes painted IS painted.
#[must_use]
pub const fn redraw(cold_client: bool, snapshot_composed: bool) -> Redraw {
    if cold_client && !snapshot_composed {
        Redraw::Jiggle
    } else {
        Redraw::Nudge
    }
}

/// Whether a FRESH spawn for a returning id should replay the transcript from disk first.
///
/// Two gates, and both are about not printing history twice. The zero sentinel can never be
/// re-presented, so journaling it would only orphan a file; and a WARM client (non-zero seq —
/// transport dropped but the app kept running) still holds its rendered grid.
#[must_use]
pub const fn restores_transcript(real_session_id: bool, last_received_seq: i64) -> bool {
    real_session_id && last_received_seq == 0
}

/// Where to pick up a pane whose shell predates this hostd — and whether that answer had to be
/// guessed.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Hash)]
pub struct SurvivorResume {
    /// The stream offset to subscribe at. [`FROM_NOW_ON`] when the position is unknown.
    pub offset: u64,
    /// Whether the transcript on disk has bytes but superd holds no position in the stream — the
    /// one case worth a log line, because the user is handed the stored transcript and then
    /// everything from now, with an unknown gap between.
    pub unpositioned: bool,
}

/// Where an adopted pane's supervised stream resumes.
///
/// The transcript on disk already holds this pane's output up to the moment the last hostd let it
/// go, and superd's ring holds the same bytes — so a subscribe from 0 hands the user their history
/// twice and re-feeds the sniffer, the block ledger and the screen engine with it.
///
/// One question, one answer, and superd holds both: it numbers the stream AND writes the file, so
/// "how much of this stream is on disk" is exact by construction. There is no staleness window to
/// trade against — superd's death takes every pane with it, so a head that could be stale belongs
/// to a pane that no longer exists.
///
/// A file with no bytes resumes from 0: there is nothing on disk to double-print.
#[must_use]
pub const fn survivor_resume(stored_bytes: u64, head: Option<u64>) -> SurvivorResume {
    if stored_bytes == 0 {
        return SurvivorResume {
            offset: 0,
            unpositioned: false,
        };
    }
    match head {
        Some(head) => {
            SurvivorResume {
                offset: head,
                unpositioned: false,
            }
        },
        None => {
            SurvivorResume {
                offset: FROM_NOW_ON,
                unpositioned: true,
            }
        },
    }
}

/// Whether a surviving pane belongs to THIS hostd and may be adopted.
///
/// Three answers, and only the middle one is not obvious:
/// - **Ours** — the owner matches.
/// - **A stranger's** — a different, non-empty owner. Left alone whatever the record says about
///   attachment: it is another daemon's pane, and the window in which it looks free is that daemon
///   restarting.
/// - **Unknown** — no owner recorded (a pane spawned before the field existed, or by a superd older
///   than protocol 1.4). Adoptable, because refusing would strand real shells on the one upgrade
///   where they most need adopting.
#[must_use]
pub fn ownership_allows_adoption(owner: &str, ours: &str) -> bool {
    owner.is_empty() || owner == ours
}

/// The prefix `SupervisedServiceProcess.paneID(for:)` builds.
///
/// MATCHED here rather than imported as a call, for the same reason hostd matched it: this side has
/// only the id, and there is no service name to ask about. A panel backend's pane id is stable by
/// design (`docs/51` §6.7) and is deliberately NOT a UUID, which is what makes the parse below a
/// classifier rather than a validity check.
pub const SERVICE_PANE_PREFIX: &str = "service:";

/// What a supervised pane that outlived a hostd is, to the hostd that just started.
///
/// Four answers, one per bucket the start-up log names. Only the first ends in an adoption; the
/// other three are shells this hostd leaves running, and the distinction between them is the whole
/// value of the type — "not adopted" covers a panel backend that will be adopted in a minute, a
/// stranger's pane that must never be, and one of our own that another live daemon is holding.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum Survivor<'a> {
    /// Ours, free, and named by a real session id: take the master back and park it.
    Adopt([u8; 16]),
    /// A panel backend, named by the service inside its id. Adopted elsewhere and later, on first
    /// use — telling an operator to end one would be advice to kill the editor.
    Service(&'a str),
    /// Not this hostd's: a stranger's owner, or an id no hostd could have written.
    Foreign,
    /// Ours, but some hostd holds a duplicate of this master RIGHT NOW.
    HeldElsewhere,
}

/// The four facts about a survivor that decide it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct SurvivorFacts<'a> {
    /// The pane's stable identity, as some hostd named it at spawn.
    pub pane_id: &'a str,
    /// Which hostd spawned it, or empty for a pane older than the field.
    pub owner: &'a str,
    /// Whether some hostd holds a duplicate of this pane's master right now.
    pub attached: bool,
    /// Whether THIS process is the one that let the pane go.
    ///
    /// The exception that makes a menu-bar host work. hostd deliberately never closes its link to
    /// superd on `stop()` — a `release` still has to travel — so a pane this process relinquished
    /// keeps reading `attached` for as long as the process lives. Without the note, the next
    /// `start()` in the same process reads its own shells as another daemon's and leaves them
    /// running for ever, reachable by no tab.
    pub relinquished_here: bool,
}

/// Which bucket a surviving pane falls in.
///
/// The ORDER is the function. The id is classified before the owner is consulted, because a
/// `service:` pane has no owner question to ask — it is not unadopted, it is adopted later. And
/// ownership is consulted before attachment, because a stranger's pane is left alone whatever it
/// says about attachment: the window in which it looks free is precisely that daemon restarting.
///
/// `ours` is this hostd's own [`owner`](SurvivorFacts::owner) string — a fact about the reader
/// rather than about the record, which is why it does not live on the facts.
#[must_use]
pub fn survivor<'a>(facts: &SurvivorFacts<'a>, ours: &str) -> Survivor<'a> {
    let Some(session) = slopdesk_ids::parse_uuid(facts.pane_id) else {
        return facts
            .pane_id
            .strip_prefix(SERVICE_PANE_PREFIX)
            .map_or(Survivor::Foreign, Survivor::Service);
    };
    if !ownership_allows_adoption(facts.owner, ours) {
        return Survivor::Foreign;
    }
    if facts.attached && !facts.relinquished_here {
        return Survivor::HeldElsewhere;
    }
    Survivor::Adopt(session)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A pane open from a well-behaved client with nothing in the way.
    const fn pane() -> OpenFacts {
        OpenFacts {
            channel_class: 0,
            incumbent: Incumbent::None,
            stopping: false,
            real_session_id: true,
            detached_store: true,
        }
    }

    #[test]
    fn a_class_this_host_does_not_route_never_reaches_the_pty_reasoning() {
        assert_eq!(
            route(OpenFacts {
                channel_class: 1,
                ..pane()
            }),
            Route::Workspace
        );
        assert_eq!(
            route(OpenFacts {
                channel_class: 2,
                ..pane()
            }),
            Route::Decline
        );
        assert_eq!(
            route(OpenFacts {
                channel_class: 255,
                ..pane()
            }),
            Route::Decline
        );
        // …including when every pane fact would otherwise have decided something else.
        assert_eq!(
            route(OpenFacts {
                channel_class: 1,
                incumbent: Incumbent::ThisKey,
                stopping: true,
                ..pane()
            }),
            Route::Workspace,
        );
    }

    #[test]
    fn a_stopping_host_refuses_before_it_can_claim_or_fork() {
        assert_eq!(
            route(OpenFacts {
                stopping: true,
                ..pane()
            }),
            Route::RefuseStopping
        );
        assert_eq!(
            route(OpenFacts {
                stopping: true,
                incumbent: Incumbent::OtherKey,
                ..pane()
            }),
            Route::RefuseStopping,
        );
    }

    #[test]
    fn a_duplicate_open_on_a_live_key_re_acks_rather_than_forking_a_second_shell() {
        assert_eq!(
            route(OpenFacts {
                incumbent: Incumbent::ThisKey,
                ..pane()
            }),
            Route::ReAck
        );
        // The re-ack wins over the claim even though the id is real and a store exists.
        assert_eq!(
            route(OpenFacts {
                incumbent: Incumbent::ThisKey,
                real_session_id: false,
                ..pane()
            }),
            Route::ReAck,
        );
    }

    #[test]
    fn a_live_id_under_another_key_joins_and_never_falls_through_to_a_spawn() {
        assert_eq!(
            route(OpenFacts {
                incumbent: Incumbent::OtherKey,
                ..pane()
            }),
            Route::Join
        );
        // The join outranks the claim: `claim` only ever finds DETACHED sessions, so a live id
        // that fell through would rotate the incumbent's journal writer out mid-session.
        assert_eq!(
            route(OpenFacts {
                incumbent: Incumbent::OtherKey,
                detached_store: false,
                ..pane()
            }),
            Route::Join,
        );
    }

    #[test]
    fn only_a_real_id_with_a_store_behind_it_is_worth_a_claim() {
        assert_eq!(route(pane()), Route::Claim);
        assert_eq!(
            route(OpenFacts {
                detached_store: false,
                ..pane()
            }),
            Route::SpawnFresh
        );
        assert_eq!(
            route(OpenFacts {
                real_session_id: false,
                ..pane()
            }),
            Route::SpawnFresh
        );
        // The sentinel cannot be looked up, so it cannot be an incumbent elsewhere either.
        assert_eq!(
            route(OpenFacts {
                incumbent: Incumbent::OtherKey,
                real_session_id: false,
                ..pane()
            }),
            Route::SpawnFresh,
        );
    }

    #[test]
    fn a_claim_answers_all_three_of_its_outcomes() {
        assert_eq!(settle(Claim::Claimed), Settled::Reattach);
        assert_eq!(settle(Claim::ReapedDeadChild), Settled::ReapThenSpawn);
        assert_eq!(settle(Claim::NotFound), Settled::SpawnFresh);
    }

    #[test]
    fn the_resume_verdict_never_exceeds_what_the_session_can_number() {
        assert_eq!(resume_from(120, 4_000), 120);
        // The adopted pane: the client remembers 4000, the fresh object has issued 1.
        assert_eq!(resume_from(4_000, 1), 1);
        assert_eq!(resume_from(4_000, 0), 0, "and zero IS the client's reset");
        assert_eq!(resume_from(0, 900), 0);
        assert_eq!(resume_from(i64::MAX, i64::MAX), i64::MAX);
        // A seq is SIGNED on the wire, and a peer that sends a negative one must not be handed a
        // verdict above every seq the session will ever assign — which is what an unsigned clamp
        // would have done with the same bits.
        assert_eq!(resume_from(-1, 900), -1);
    }

    #[test]
    fn only_a_cold_client_on_a_raw_replay_earns_the_jiggle() {
        assert_eq!(redraw(true, false), Redraw::Jiggle);
        assert_eq!(redraw(true, true), Redraw::Nudge);
        assert_eq!(redraw(false, false), Redraw::Nudge);
        assert_eq!(redraw(false, true), Redraw::Nudge);
    }

    #[test]
    fn a_warm_client_and_the_zero_sentinel_are_both_refused_the_transcript() {
        assert!(restores_transcript(true, 0));
        assert!(
            !restores_transcript(true, 1),
            "a warm client still holds its rendered grid"
        );
        assert!(
            !restores_transcript(false, 0),
            "the sentinel's transcript would be an orphan"
        );
    }

    #[test]
    fn a_survivor_resumes_at_the_position_superd_wrote_and_nowhere_else() {
        assert_eq!(
            survivor_resume(0, Some(900)),
            SurvivorResume {
                offset: 0,
                unpositioned: false
            },
            "an empty file has nothing to double-print",
        );
        assert_eq!(survivor_resume(4_096, Some(4_096)), SurvivorResume {
            offset: 4_096,
            unpositioned: false
        },);
        assert_eq!(survivor_resume(4_096, None), SurvivorResume {
            offset: FROM_NOW_ON,
            unpositioned: true
        },);
    }

    #[test]
    fn an_unowned_pane_is_adoptable_and_a_strangers_is_not() {
        assert!(ownership_allows_adoption(
            "hostd port=7777 state=default",
            "hostd port=7777 state=default"
        ));
        assert!(!ownership_allows_adoption(
            "hostd port=7778 state=default",
            "hostd port=7777 state=default"
        ));
        assert!(ownership_allows_adoption("", "hostd port=7777 state=default"));
    }

    /// This hostd, as superd records it.
    const OURS: &str = "hostd port=7777 state=default";

    /// A free pane of ours, named by a real session id.
    const fn survived() -> SurvivorFacts<'static> {
        SurvivorFacts {
            pane_id: "1B4E28BA-2FA1-11D2-883F-0016D3CCA427",
            owner: OURS,
            attached: false,
            relinquished_here: false,
        }
    }

    #[test]
    fn a_free_pane_of_ours_is_taken_back_under_the_id_its_journal_is_filed_by() {
        assert_eq!(
            survivor(&survived(), OURS),
            Survivor::Adopt(slopdesk_ids::parse_uuid(survived().pane_id).unwrap_or_default()),
            "the id that comes back is the pane's OWN — a fresh one would file its journal, its hook route \
             and its every future reattach under a conversation nobody has had"
        );
    }

    #[test]
    fn a_panel_backend_is_named_by_its_service_rather_than_counted_as_unadopted() {
        assert_eq!(
            survivor(
                &SurvivorFacts {
                    pane_id: "service:code-server",
                    ..survived()
                },
                OURS
            ),
            Survivor::Service("code-server"),
            "it is not unadopted — it is adopted elsewhere and later, on first use"
        );
    }

    #[test]
    fn a_panel_backend_is_classified_before_anyone_asks_who_owns_it() {
        // A service pane spawned by a stranger, and one this process is holding. Neither question
        // is asked: the id alone decides, which is what keeps the bucket stable across the
        // ownership rules changing underneath it.
        for facts in [
            SurvivorFacts {
                pane_id: "service:code-server",
                owner: "hostd port=7778 state=default",
                ..survived()
            },
            SurvivorFacts {
                pane_id: "service:code-server",
                attached: true,
                ..survived()
            },
        ] {
            assert_eq!(survivor(&facts, OURS), Survivor::Service("code-server"));
        }
    }

    #[test]
    fn an_id_no_hostd_could_have_written_is_left_running_rather_than_guessed_at() {
        assert_eq!(
            survivor(
                &SurvivorFacts {
                    pane_id: "not-a-uuid",
                    ..survived()
                },
                OURS
            ),
            Survivor::Foreign
        );
    }

    #[test]
    fn a_strangers_pane_is_left_alone_whatever_it_says_about_attachment() {
        for attached in [false, true] {
            assert_eq!(
                survivor(
                    &SurvivorFacts {
                        owner: "hostd port=7778 state=default",
                        attached,
                        ..survived()
                    },
                    OURS
                ),
                Survivor::Foreign,
                "the window in which a stranger's pane looks free is that daemon restarting"
            );
        }
    }

    #[test]
    fn an_attached_pane_is_held_unless_this_very_process_is_the_one_that_let_it_go() {
        assert_eq!(
            survivor(
                &SurvivorFacts {
                    attached: true,
                    ..survived()
                },
                OURS
            ),
            Survivor::HeldElsewhere,
            "taking it would put a second daemon's shell on this one's journal file"
        );
        assert!(
            matches!(
                survivor(
                    &SurvivorFacts {
                        attached: true,
                        relinquished_here: true,
                        ..survived()
                    },
                    OURS
                ),
                Survivor::Adopt(_)
            ),
            "hostd never closes its link on stop, so its own released panes still read attached"
        );
    }

    #[test]
    fn a_pane_with_no_owner_recorded_is_adopted_rather_than_stranded_on_the_upgrade() {
        assert!(
            matches!(
                survivor(
                    &SurvivorFacts {
                        owner: "",
                        ..survived()
                    },
                    OURS
                ),
                Survivor::Adopt(_)
            ),
            "refusing here would strand real shells on the one upgrade that most needs adopting"
        );
    }
}
