//! Whether a pane may dial, which write of the layout wins, and whose picture the cache holds.
//!
//! The workspace store keeps three things that are not facts about the tree and not runtime
//! plumbing either: a gate that decides whether the panes on screen may open host channels at all,
//! a monotonic guard that decides which of two racing writes of `workspace.json` is allowed to
//! land, and a rule about which host the cached picture of the document may honestly be filed
//! under. All three were stored properties on a `@MainActor @Observable` class, mutated from a
//! handful of places each, with the deciding written out at the asking site.
//!
//! Each of them is state AND the decisions over that state — [`store_video_slots`] and `docs/55`
//! §4b's test for a handle — so they live here together, behind one, because they share the counter
//! at the top of the file.
//!
//! ## The revision is the reason this is ONE handle
//!
//! [`WorkspaceCore::revision`] is both the projection cache's key on the near side and the
//! Observation shadow every reader of the tree binds to. Splitting the gate from the guard would
//! give that counter two owners, and a memo keyed on a number neither side fully controls is a
//! layout that either repaints for nothing or freezes. It over-invalidates by design: a revision
//! that moves too often costs one projection, and one that moves too rarely costs the frame.
//!
//! ## Nothing here learns an identity
//!
//! A pane, a tab and a session are UUIDs the caller owns, and not one of them appears. What crosses
//! is a `host:port` — a VALUE the store also persists and prints, not a handle to anything — plus
//! the small enum of what the workspace channel currently is. The caller does the effects: it holds
//! the `Task` the backstop runs on, it walks its own panes when told to fan out, and it writes its
//! own file when told the generation is still current.
//!
//! ## What is deliberately NOT here
//!
//! The rings, the switcher, the attention walk and the close-confirmation truth table. Their policy
//! crossed already — [`store_rollup::push`](crate::store_rollup::push),
//! [`pane_switcher`](crate::pane_switcher), [`attention_fold`](crate::attention_fold),
//! [`close_confirm`](crate::close_confirm) — and only their STORAGE is still near-side. Moving
//! storage across to join them would add a crossing per mutation to relocate a decision that is
//! already on this side, which is the opposite of what the boundary is for.
//!
//! [`store_video_slots`]: crate::store_video_slots

/// What the workspace channel is, as far as the dial gate is concerned.
///
/// The store mirrors a richer state — `idle`, `opening`, `live`, `closed`, `refused` — but the gate
/// draws exactly two lines through it, and collapsing the rest into [`Attached`](Channel::Attached)
/// is what keeps the arms below from reading as a state machine they are not.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub enum Channel {
    /// No channel at all: a headless client, or a unit test. Nothing is coming, so nothing is
    /// waited for.
    #[default]
    Absent,
    /// The host answered that it does not serve the workspace channel class. It will therefore
    /// never publish a document, so nothing about the layout on screen can ever be confirmed
    /// and holding for it would hold for the life of the process.
    Refused,
    /// The channel serves an in-process document, whose loopback adopted the very mirror this store
    /// seeded. The ids on screen came from here.
    LocalDocument,
    /// A real host channel, in any of its live states — including `closed`.
    ///
    /// `closed` belongs here rather than beside [`Refused`](Channel::Refused), and reading it as an
    /// answer is what made a host switch churn: the app tears the shared connection down BEFORE it
    /// commits the new target, so the state at the moment the gate is recomputed is `closed` with
    /// the PREVIOUS host's document still on screen. A dead subscription says nothing about whose
    /// ids these are. The provenance arm does, and a close with no reconnect behind it is what the
    /// backstop bounds.
    Attached,
}

/// What the caller must do with the wall clock the current hold may not outlive.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Backstop {
    /// Nothing changed; leave whatever is armed exactly as it is.
    Leave,
    /// A hold has begun. Start the timer, and call [`WorkspaceCore::note_backstop_expired`] if it
    /// runs out with no answer.
    Arm,
    /// An answer arrived. Cancel the timer, so a hold that releases and re-engages at a second host
    /// gets its own full window rather than the remainder of the first.
    Cancel,
}

/// What one recomputation of the dial gate asks the caller to do.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct GateEdge {
    /// Whether the gate's published answer moved at all.
    pub changed: bool,
    /// The RELEASING edge: the hold is over and everything it was holding should now be dialled.
    ///
    /// A store-level fan-out, not something only a mounted leaf can do. A mounted leaf's own arm
    /// re-fires on this same edge, but a pane in a satellite window — or any leaf not mounted yet —
    /// would otherwise wait for an unrelated event to nudge it.
    pub opened: bool,
    /// What to do with the backstop timer.
    pub backstop: Backstop,
}

/// What one folded document frame asks the caller to do, past the effects it already ran.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct FrameEdge {
    /// Whether this frame stamped the attached host as the one that vouches for the ids on screen.
    pub provenance_stamped: bool,
    /// The gate recomputation that frame implied.
    pub gate: GateEdge,
    /// Whether a booked re-dial fan-out came due on this frame — the one instant at which it is
    /// both possible and legitimate, because the pane set is back on screen AND its provenance
    /// is settled.
    pub redial_booking_fired: bool,
}

/// The three facts about the near side the gate cannot know on its own, handed in on every call.
///
/// They are ARGUMENTS rather than fields for one reason: each of them lives on an object the core
/// has never seen — a channel client, a dictionary of automation variables, the mirror's own
/// pending set — and a copy of a fact whose owner is elsewhere is a copy that goes stale between
/// the write that moved it and the call that remembers to push it. Passing them makes that
/// impossible.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct Inputs {
    /// What the workspace channel is.
    pub channel: Channel,
    /// The automation bootstrap owns this launch's layout and publishes it itself, so there is
    /// nothing for the gate to wait on.
    pub bootstrap_armed: bool,
    /// This launch's `adoptWorkspace` proposal is still outstanding. What is on screen is a
    /// PREDICTION until the verdict lands, so nothing in it may open a shell.
    pub offer_pending: bool,
}

/// The launch dial hold: whether the panes on screen may open their host channels yet.
///
/// SHOWING a pane and OPENING a shell for it are different acts, and an optimistic overlay only
/// buys the first one. The host spawns a fresh shell for any session id it does not know, so a pane
/// that dials an id host truth does not carry gets a shell — and if the layout it belongs to is
/// then replaced, that shell is abandoned with nobody attached.
///
/// The rule is PROVENANCE: a pane may dial an id at the host that named it, and nowhere else. Two
/// windows in a run that put an unconfirmed layout on screen — a launch offering a restored
/// `workspace.json` to a host that may already have a workspace, and a mid-run connect to a second
/// machine that has published nothing — are the same window seen twice. Measured on hardware, one
/// host and two launches with divergent ids: three panes on screen, six shells spawned.
#[derive(Clone, Debug, Default)]
struct DialGate {
    /// The published answer, which is what a pane actually reads.
    open: bool,
    /// The `host:port` whose OWN document the panes on screen came from, or `None` while nothing a
    /// host published has landed.
    ///
    /// An OPTION and not an empty string, and the distinction is the whole cold-launch case: the
    /// attached host is empty too before any target is committed, so a `""` here would read as
    /// "this host named these ids" for every store that has not connected yet — and every restored
    /// pane would dial into a subscription that has said nothing.
    confirmed_host: Option<String>,
    /// The `host:port` this run is attached to now, or empty before any target is committed.
    attached_host: String,
    /// The current hold EPISODE — the two bits that belong to the wall clock rather than to the
    /// rule, and that a new host resets together.
    hold: Hold,
}

/// One hold episode's clock, which is the only thing that can open a gate the rule wants shut.
#[derive(Clone, Copy, Debug, Default)]
struct Hold {
    /// The backstop has run out on THIS episode, which opens the gate whatever the provenance says:
    /// a hold with no release is a window of panes that never connect, and that is strictly worse
    /// than the churn it prevents.
    expired: bool,
    /// Whether a backstop is believed to be running, so the caller is asked to arm one exactly once
    /// per episode.
    backstop_armed: bool,
}

impl DialGate {
    /// The rule. Every arm is a reason there is nothing left to wait for.
    fn resolve(&self, inputs: Inputs) -> bool {
        if inputs.offer_pending {
            return false;
        }
        match inputs.channel {
            Channel::Absent | Channel::Refused | Channel::LocalDocument => return true,
            Channel::Attached => {},
        }
        if inputs.bootstrap_armed {
            return true;
        }
        if self.confirmed_host.as_deref() == Some(self.attached_host.as_str()) {
            return true;
        }
        self.hold.expired
    }

    /// Recomputes the published answer and reports what the caller owes the world.
    fn refresh(&mut self, inputs: Inputs) -> GateEdge {
        let next = self.resolve(inputs);
        let backstop = if next {
            if self.hold.backstop_armed {
                self.hold.backstop_armed = false;
                Backstop::Cancel
            } else {
                Backstop::Leave
            }
        } else if self.hold.backstop_armed || self.hold.expired {
            Backstop::Leave
        } else {
            self.hold.backstop_armed = true;
            Backstop::Arm
        };
        let changed = next != self.open;
        self.open = next;
        GateEdge {
            changed,
            opened: changed && next,
            backstop,
        }
    }
}

/// A monotonic guard over the debounced write of the layout.
///
/// A burst of mutations coalesces into one write, and the task that performs it may already be past
/// its sleep when a newer mutation supersedes it — cancellation cannot stop that one. So the write
/// re-checks its captured generation before touching the file, and the trailing handle-clear does
/// too: a superseded task may neither clobber the file with a stale snapshot nor nil out the newest
/// handle and strand it uncancellable.
#[derive(Clone, Copy, Debug, Default)]
struct SaveGuard {
    /// The live generation. Bumped by every scheduled and every immediate write.
    generation: u64,
    /// Whether writes are armed at all. Off during construction, because the initial reconcile
    /// would otherwise re-write a just-loaded file with identical bytes.
    enabled: bool,
}

/// Which host the cached picture of the document may honestly be filed under.
///
/// The cache is a picture of ONE machine: the facts in it are absolute paths on that machine's
/// filesystem. A connect to a host other than the one this run was seeded from leaves the mirror
/// holding a mix of two, and a mixed picture belongs to neither — so it stops being written rather
/// than filing one host's folders under the other's name. The next launch seeds from whichever host
/// the MRU then names, so this self-heals in one launch instead of persisting a blend forever.
#[derive(Clone, Debug, Default)]
struct CacheProvenance {
    /// The `host:port` the cache was seeded from at launch.
    seed: String,
    /// The `host:port` it is written under now. Empty reads as nothing and writes nothing: a
    /// picture with no host on it can never be shown to the right one.
    current: String,
}

/// The workspace store's decisions, and the counter every projection of it is keyed on.
///
/// See the module documentation for what is here, what is not, and why the three subjects share one
/// handle rather than three.
#[derive(Clone, Debug, Default)]
pub struct WorkspaceCore {
    revision: u64,
    dial: DialGate,
    save: SaveGuard,
    cache: CacheProvenance,
    /// The document-frame count the provenance stamp last acted on, so a repaint is told from a
    /// frame. Goes backwards when the mirror resets, which is what makes a re-subscribe unconfirmed
    /// again.
    last_folded_frames: u64,
    /// An app-connection establish still owes its panes a fan-out. Set on every establish, spent by
    /// the first document frame the attached host folds.
    redial_awaits_document: bool,
}

impl WorkspaceCore {
    /// A core for a store whose cache was seeded from `cache_host_key` (empty for the headless and
    /// test paths, which read and write nothing).
    ///
    /// The gate starts OPEN. A store with no channel has nothing to wait for, and the four callers
    /// that can give it one all recompute the gate as they do.
    #[must_use]
    pub fn new(cache_host_key: &str) -> Self {
        Self {
            revision: 0,
            dial: DialGate {
                open: true,
                ..DialGate::default()
            },
            save: SaveGuard::default(),
            cache: CacheProvenance {
                seed: cache_host_key.to_owned(),
                current: cache_host_key.to_owned(),
            },
            last_folded_frames: 0,
            redial_awaits_document: false,
        }
    }

    // MARK: the revision

    /// The projection key as it stands.
    #[must_use]
    pub const fn revision(&self) -> u64 {
        self.revision
    }

    /// Moves the projection key for a change this core cannot see: a frame folded into the mirror,
    /// the divider drag preview, this device's own focus overlay.
    ///
    /// The two LOCAL overlays move it even though nothing in the document did, because this counter
    /// is both the cache key and the near side's Observation shadow — a drag frame that skipped it
    /// would neither repaint nor invalidate. Everything this core decides ITSELF bumps through
    /// [`refresh_gate`](Self::refresh_gate) instead; the caller never adds one to the number.
    pub const fn bump_revision(&mut self) -> u64 {
        self.revision = self.revision.wrapping_add(1);
        self.revision
    }

    // MARK: the dial gate

    /// Recomputes the gate and moves the projection key when the published answer moved.
    ///
    /// The bump belongs HERE rather than at each call site, and that is the whole reason these
    /// subjects share one handle: `panes_may_dial` is read through the same memo the document's
    /// projections are keyed on, so a counter whose moves are decided in two places is a counter
    /// neither side can be held to. Every door below that can move the gate goes through this one.
    fn refresh_gate(&mut self, inputs: Inputs) -> GateEdge {
        let edge = self.dial.refresh(inputs);
        if edge.changed {
            self.revision = self.revision.wrapping_add(1);
        }
        edge
    }

    /// Whether the panes on screen may open their host channels.
    #[must_use]
    pub const fn panes_may_dial(&self) -> bool {
        self.dial.open
    }

    /// Recomputes the gate against `inputs`.
    ///
    /// The one door for every site that moves a near-side fact without folding a frame: the
    /// channel's own state changes, the launch offer going out and coming back, the automation
    /// bootstrap taking over the launch. One entry point rather than one per fact, because three
    /// setters would each publish an edge against two facts they did not receive.
    pub fn refresh_dial_gate(&mut self, inputs: Inputs) -> GateEdge {
        self.refresh_gate(inputs)
    }

    /// The backstop ran out with no answer of any kind. Opens the hold and recomputes.
    pub fn note_backstop_expired(&mut self, inputs: Inputs) -> GateEdge {
        self.dial.hold = Hold {
            expired: true,
            backstop_armed: false,
        };
        self.refresh_gate(inputs)
    }

    /// The `host:port` whose document the panes on screen came from, or empty while none has
    /// landed.
    #[must_use]
    pub fn confirmed_host(&self) -> Option<&str> {
        self.dial.confirmed_host.as_deref()
    }

    /// The `host:port` this run is attached to now.
    #[must_use]
    pub fn attached_host(&self) -> &str {
        &self.dial.attached_host
    }

    // MARK: the connect

    /// A connect committed `host_key` as this run's target.
    ///
    /// Runs BEFORE the connection reports up, which is why the hold is already in place by the time
    /// the establish fan-out asks every pane to dial. A DIFFERENT host is a new hold with its own
    /// full window, and it also retires the cached picture for the rest of the run.
    pub fn commit_connection_target(&mut self, inputs: Inputs, host_key: &str) -> GateEdge {
        let moved = self.dial.attached_host != host_key;
        host_key.clone_into(&mut self.dial.attached_host);
        self.cache.current = if host_key == self.cache.seed {
            host_key.to_owned()
        } else {
            String::new()
        };
        if !moved {
            return GateEdge {
                changed: false,
                opened: false,
                backstop: Backstop::Leave,
            };
        }
        // A new host is a new hold, with its own full window rather than the remainder of the
        // first.
        self.dial.hold = Hold::default();
        self.refresh_gate(inputs)
    }

    // MARK: the folded frame

    /// Books the establish fan-out a second run, on the first document frame the attached host
    /// folds.
    ///
    /// A one-shot per establish. An establish that dials what is on screen and then re-opens the
    /// subscription empties the mirror, so an establish that finds it ALREADY empty has no pane set
    /// to fan across and no gate edge coming — the host that confirmed those ids is still the host
    /// being dialled. This is the missing edge.
    pub const fn arm_redial_on_document(&mut self) {
        self.redial_awaits_document = true;
    }

    /// A document frame folded: stamp the provenance if this is a new one, recompute the gate, and
    /// answer whether the booked fan-out came due.
    ///
    /// Gated on the FRAME COUNT rather than on being called: an optimistic patch, a fast-path push
    /// and a presence roster all announce themselves through the same hook, and any of them landing
    /// after a new target is committed but before the re-subscribe answers would stamp the previous
    /// host's layout with the new host's name.
    ///
    /// `inputs.offer_pending` is re-read from the mirror on every frame rather than remembered,
    /// because the frame BEHIND a proposal retiring it and an `intentResult` snapping it away are
    /// both answers and neither is announced any other way.
    pub fn note_document_frame(
        &mut self,
        inputs: Inputs,
        frames_applied: u64,
        epoch_is_seed: bool,
    ) -> FrameEdge {
        let mut provenance_stamped = false;
        if frames_applied != self.last_folded_frames {
            self.last_folded_frames = frames_applied;
            // The store's own seed is not a host's answer; it is the question.
            if frames_applied > 0 && !epoch_is_seed {
                self.dial.confirmed_host = Some(self.dial.attached_host.clone());
                provenance_stamped = true;
            }
        }
        let gate = self.refresh_gate(inputs);
        // Left armed while either half is missing: a hold released by the backstop with no document
        // behind it dials an empty tree, and disarming there would spend the booking on nothing.
        let due = self.redial_awaits_document
            && self.dial.open
            && self.dial.confirmed_host.as_deref() == Some(self.dial.attached_host.as_str());
        if due {
            self.redial_awaits_document = false;
        }
        FrameEdge {
            provenance_stamped,
            gate,
            redial_booking_fired: due,
        }
    }

    /// Whether the armed launch offer may go out now: the mirror holds a REAL host document, no
    /// automation bootstrap owns this launch, and the caller says the store may mutate.
    ///
    /// The seed IS the tree the offer would carry, so offering it back to an in-process document
    /// that already adopted it would spend the host's one pristine chance on a no-op.
    #[must_use]
    pub const fn launch_offer_ready(inputs: Inputs, known_epoch_is_seed: bool, can_mutate: bool) -> bool {
        can_mutate && !inputs.bootstrap_armed && !known_epoch_is_seed
    }

    // MARK: the save guard

    /// Arms the debounced write, after the construction reconcile that would otherwise re-write a
    /// just-loaded file with identical bytes.
    pub const fn enable_saving(&mut self) {
        self.save.enabled = true;
    }

    /// Claims a generation for a debounced write, or `None` while writes are disarmed.
    ///
    /// The caller captures the answer, sleeps out its debounce, and asks
    /// [`is_current_save_generation`](Self::is_current_save_generation) before it writes.
    pub const fn begin_save(&mut self) -> Option<u64> {
        if !self.save.enabled {
            return None;
        }
        self.save.generation = self.save.generation.wrapping_add(1);
        Some(self.save.generation)
    }

    /// Claims a generation for a write happening RIGHT NOW, whatever is in flight.
    ///
    /// Unlike [`begin_save`](Self::begin_save) this does not consult the arming flag: the immediate
    /// write is the app-backgrounding path, and the caller has already decided it is writing. The
    /// bump is what makes any already-past-sleep debounced task lose the trailing guard, so it can
    /// neither resurrect nor nil the handle after this write.
    pub const fn supersede_save(&mut self) -> u64 {
        self.save.generation = self.save.generation.wrapping_add(1);
        self.save.generation
    }

    /// Whether a captured generation is still the live one.
    #[must_use]
    pub const fn is_current_save_generation(&self, generation: u64) -> bool {
        self.save.generation == generation
    }

    /// The live generation, as a value.
    ///
    /// The predicate above is what a write path asks; this is what an OBSERVER asks — whether a
    /// mutation moved the guard at all, which no claim-and-compare can answer without also
    /// claiming.
    #[must_use]
    pub const fn save_generation(&self) -> u64 {
        self.save.generation
    }

    /// Whether debounced writes are armed at all — the same guard the cache's own debounce runs,
    /// which is why it is readable rather than only consultable through
    /// [`begin_save`](Self::begin_save).
    #[must_use]
    pub const fn saving_enabled(&self) -> bool {
        self.save.enabled
    }

    // MARK: the cache provenance

    /// The `host:port` the cached picture is written under, or empty when it may not be written.
    #[must_use]
    pub fn cache_host_key(&self) -> &str {
        &self.cache.current
    }
}

#[cfg(test)]
#[expect(clippy::expect_used, reason = "a panic in a test is the failure report")]
mod tests {
    use super::{Backstop, Channel, Inputs, WorkspaceCore};

    /// The inputs of a store with no channel: a headless client, or a unit test that asked for
    /// none.
    const HEADLESS: Inputs = Inputs {
        channel: Channel::Absent,
        bootstrap_armed: false,
        offer_pending: false,
    };

    /// The inputs of a store attached to a real host, with no offer out and no bootstrap.
    const ATTACHED: Inputs = Inputs {
        channel: Channel::Attached,
        bootstrap_armed: false,
        offer_pending: false,
    };

    /// A core attached to `host`, with a document that host has vouched for.
    fn settled_at(host: &str) -> WorkspaceCore {
        let mut core = WorkspaceCore::new(host);
        core.commit_connection_target(ATTACHED, host);
        core.note_document_frame(ATTACHED, 1, false);
        core
    }

    #[test]
    fn a_store_with_no_channel_waits_for_nothing() {
        let mut core = WorkspaceCore::new("");
        core.refresh_dial_gate(HEADLESS);
        assert!(
            core.panes_may_dial(),
            "a headless client has no host to be confirmed by"
        );
    }

    #[test]
    fn an_outstanding_launch_offer_outranks_every_other_arm() {
        // Settled at a host that has vouched for the ids on screen, so nothing but the offer itself
        // can shut the gate. That is the whole claim: a proposal is the ONE op whose answer the
        // client cannot predict, so it is read before the arms that would otherwise open.
        let mut core = settled_at("studio:7070");
        assert!(core.panes_may_dial());
        let edge = core.refresh_dial_gate(Inputs {
            offer_pending: true,
            ..ATTACHED
        });
        assert!(
            !core.panes_may_dial(),
            "what is on screen is a prediction until the verdict lands"
        );
        assert!(edge.changed);
        assert_eq!(
            edge.backstop,
            Backstop::Arm,
            "a hold with no release is worse than the churn"
        );
    }

    #[test]
    fn a_channel_with_no_committed_target_still_holds() {
        // The case an empty-string "confirmed host" got wrong: a subscription is open, but no
        // connect has committed a target yet, so BOTH sides of the provenance test are empty. That
        // is not a host vouching for these ids — it is a host that has said nothing.
        let mut core = WorkspaceCore::new("");
        let edge = core.refresh_dial_gate(ATTACHED);
        assert!(
            !core.panes_may_dial(),
            "an unanswered subscription confirms nothing"
        );
        assert!(edge.changed, "the gate started open and this closed it");
        assert_eq!(edge.backstop, Backstop::Arm, "and the hold is bounded from here");
    }

    #[test]
    fn a_cold_launch_holds_before_any_host_has_spoken() {
        let mut core = WorkspaceCore::new("studio:7070");
        let edge = core.commit_connection_target(ATTACHED, "studio:7070");
        assert!(!core.panes_may_dial(), "no host has named these ids yet");
        assert!(
            edge.changed,
            "the gate starts open, because a store with no channel waits for nothing",
        );
        assert_eq!(edge.backstop, Backstop::Arm);
    }

    #[test]
    fn the_frame_behind_a_proposal_releases_the_hold_and_fans_out() {
        let mut core = WorkspaceCore::new("studio:7070");
        core.commit_connection_target(ATTACHED, "studio:7070");
        core.refresh_dial_gate(Inputs {
            offer_pending: true,
            ..ATTACHED
        });
        let edge = core.note_document_frame(ATTACHED, 1, false);
        assert!(edge.provenance_stamped, "this host named the ids now on screen");
        assert!(
            edge.gate.opened,
            "the releasing edge is what dials the panes the hold was holding"
        );
        assert_eq!(edge.gate.backstop, Backstop::Cancel);
        assert!(core.panes_may_dial());
    }

    #[test]
    fn a_refused_channel_is_a_definite_answer_and_a_closed_one_is_not() {
        let mut core = WorkspaceCore::new("studio:7070");
        core.commit_connection_target(ATTACHED, "elsewhere:7070");
        assert!(
            !core.panes_may_dial(),
            "a dead subscription says nothing about whose ids these are",
        );
        core.refresh_dial_gate(Inputs {
            channel: Channel::Refused,
            ..ATTACHED
        });
        assert!(
            core.panes_may_dial(),
            "a host that serves no document can never confirm anything"
        );
    }

    #[test]
    fn the_store_s_own_seed_never_stamps_provenance() {
        let mut core = WorkspaceCore::new("studio:7070");
        core.commit_connection_target(ATTACHED, "studio:7070");
        let edge = core.note_document_frame(ATTACHED, 1, true);
        assert!(
            !edge.provenance_stamped,
            "the seed is the question, not the answer"
        );
        assert!(core.confirmed_host().is_none(), "no host has named these ids yet");
        assert!(!core.panes_may_dial());
    }

    #[test]
    fn a_repaint_is_told_from_a_frame() {
        let mut core = settled_at("studio:7070");
        core.commit_connection_target(ATTACHED, "elsewhere:7070");
        let edge = core.note_document_frame(ATTACHED, 1, false);
        assert!(
            !edge.provenance_stamped,
            "the same frame count re-announced is the previous host's layout, not the new host's",
        );
        assert_eq!(core.confirmed_host(), Some("studio:7070"));
        assert!(!core.panes_may_dial(), "the new host has published nothing yet");
    }

    #[test]
    fn a_host_switch_starts_a_hold_with_its_own_full_window() {
        let mut core = settled_at("studio:7070");
        core.note_backstop_expired(ATTACHED);
        assert!(
            core.panes_may_dial(),
            "an expired hold opens whatever the provenance says"
        );
        let edge = core.commit_connection_target(ATTACHED, "elsewhere:7070");
        assert!(
            edge.changed,
            "a different host is a different layout, unconfirmed"
        );
        assert_eq!(
            edge.backstop,
            Backstop::Arm,
            "and it gets its own window, not the remainder"
        );
        assert!(!core.panes_may_dial());
    }

    #[test]
    fn a_reconnect_to_the_same_host_confirms_nothing_new_and_holds_nothing() {
        let mut core = settled_at("studio:7070");
        let edge = core.commit_connection_target(ATTACHED, "studio:7070");
        assert!(!edge.changed);
        assert_eq!(
            edge.backstop,
            Backstop::Leave,
            "no episode began, so no timer starts"
        );
        assert!(core.panes_may_dial());
    }

    #[test]
    fn one_backstop_is_armed_per_hold_episode() {
        let mut core = WorkspaceCore::new("studio:7070");
        let first = core.commit_connection_target(ATTACHED, "studio:7070");
        assert_eq!(first.backstop, Backstop::Arm);
        let second = core.refresh_dial_gate(ATTACHED);
        assert_eq!(
            second.backstop,
            Backstop::Leave,
            "the episode already has its timer"
        );
        assert!(!second.changed);
    }

    #[test]
    fn the_automation_bootstrap_owns_its_own_launch() {
        let mut core = WorkspaceCore::new("studio:7070");
        core.commit_connection_target(ATTACHED, "elsewhere:7070");
        assert!(!core.panes_may_dial());
        let armed = Inputs {
            bootstrap_armed: true,
            ..ATTACHED
        };
        let edge = core.refresh_dial_gate(armed);
        assert!(edge.opened, "the bootstrap publishes the layout it dialled");
        assert!(
            !WorkspaceCore::launch_offer_ready(armed, false, true),
            "and it does not also offer one",
        );
    }

    #[test]
    fn the_launch_offer_waits_for_a_host_that_has_spoken() {
        assert!(
            !WorkspaceCore::launch_offer_ready(ATTACHED, true, true),
            "the seed is this very tree",
        );
        assert!(
            !WorkspaceCore::launch_offer_ready(ATTACHED, false, false),
            "and a store that cannot mutate offers nothing",
        );
        assert!(WorkspaceCore::launch_offer_ready(ATTACHED, false, true));
    }

    #[test]
    fn a_booked_fan_out_waits_for_the_pane_set_and_its_provenance_together() {
        let mut core = WorkspaceCore::new("studio:7070");
        core.commit_connection_target(ATTACHED, "studio:7070");
        core.arm_redial_on_document();
        let seeded = core.note_document_frame(ATTACHED, 1, true);
        assert!(
            !seeded.redial_booking_fired,
            "the booking is not spent on the store's own seed"
        );
        let real = core.note_document_frame(ATTACHED, 2, false);
        assert!(
            real.redial_booking_fired,
            "this is the one instant it is both possible and legitimate",
        );
        let again = core.note_document_frame(ATTACHED, 3, false);
        assert!(!again.redial_booking_fired, "one shot per establish");
    }

    #[test]
    fn the_cache_belongs_to_one_machine() {
        let mut core = WorkspaceCore::new("studio:7070");
        assert_eq!(core.cache_host_key(), "studio:7070");
        core.commit_connection_target(ATTACHED, "elsewhere:7070");
        assert!(
            core.cache_host_key().is_empty(),
            "a mixed picture belongs to neither host"
        );
        core.commit_connection_target(ATTACHED, "studio:7070");
        assert_eq!(
            core.cache_host_key(),
            "studio:7070",
            "and the seed's own host may be written again",
        );
    }

    #[test]
    fn writes_are_disarmed_until_the_construction_reconcile_is_over() {
        let mut core = WorkspaceCore::new("");
        assert!(!core.saving_enabled());
        assert!(
            core.begin_save().is_none(),
            "a just-loaded file is not re-written with its own bytes",
        );
        core.enable_saving();
        assert!(core.begin_save().is_some());
    }

    #[test]
    fn a_superseded_write_loses_to_the_one_that_superseded_it() {
        let mut core = WorkspaceCore::new("");
        core.enable_saving();
        let stale = core.begin_save().expect("saving is armed");
        let fresh = core.begin_save().expect("saving is armed");
        assert!(
            !core.is_current_save_generation(stale),
            "cancellation cannot stop a task past its sleep",
        );
        assert!(core.is_current_save_generation(fresh));
        core.supersede_save();
        assert!(
            !core.is_current_save_generation(fresh),
            "and an immediate write outranks both"
        );
    }

    #[test]
    fn the_revision_moves_for_a_local_overlay_that_moved_no_document() {
        let mut core = WorkspaceCore::new("");
        let before = core.revision();
        assert_eq!(core.bump_revision(), before + 1);
        assert_eq!(
            core.revision(),
            before + 1,
            "the cache key and the observation shadow are one counter",
        );
    }
}
