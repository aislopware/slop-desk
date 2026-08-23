//! Whether the frontmost app can go back and forward, and every decision around finding out.
//!
//! The swipe-nav chip must not promise a navigation the browser cannot perform: Back greyed out
//! means ⌘[ is a no-op, so a chip that lit anyway would animate a page turn that never happened
//! (`docs/20` §9.6). The ANSWER comes from the accessibility tree, which is `slopdesk-apple-ax`'s;
//! what is here is everything that is not an IPC round trip — which strategy a node belongs to,
//! how far a walk may go, when a cached pair may be trusted, and how two half-answers fold into
//! one flag pair or into nothing.
//!
//! ## The two strategies, and why the order is not a preference
//! **The toolbar pair** — the buttons carrying `AXIdentifier` `BackButton`/`ForwardButton` — is
//! preferred because it is what the person SEES grey out. Safari's autoenabled MENUS validate
//! lazily and keep reporting a background navigation's stale state, and stale in that direction is
//! the dangerous one: the chip stays hidden while the chord would have worked.
//!
//! **The menu pair** — the items whose key equivalent is ⌘[ / ⌘] — is the fallback, and it is
//! semantically exact rather than approximate: it asks "would the chord we are about to send do
//! anything". It is also locale-independent, because a key equivalent is not a title. Chromium's
//! `CommandUpdater` keeps those items live without any menu ever opening.
//!
//! The two differ in one way that outlives the scan, and it is the reason [`Strategy`] is carried
//! rather than discarded once a pair is found: toolbar state is per-WINDOW, and menu state is
//! app-global. A toolbar pair scanned from window A keeps answering successfully after focus moves
//! to window B of the same app — no AX error, just window A's history served as B's, forever. See
//! [`Cache::plan`].
//!
//! Every arm below was unreachable from a test before it moved: the Swift this replaced needed a
//! live browser and the Accessibility grant to run a single line, and its own header said so.

/// Which way a history control points.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Direction {
    /// The Back control — ⌘[.
    Back,
    /// The Forward control — ⌘].
    Forward,
}

/// Which of the two readings a cached pair came from.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Strategy {
    /// Toolbar buttons, scanned from one window. Per-window state; see [`Cache::plan`].
    Toolbar,
    /// Menu items with a ⌘-only key equivalent. App-global, and focus-following by construction.
    Menu,
}

/// Both directions, as the wire carries them.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Flags {
    /// Whether ⌘[ would navigate.
    pub can_go_back: bool,
    /// Whether ⌘] would navigate.
    pub can_go_forward: bool,
}

/// Per-element messaging cap, seconds. The framework default is ~6 s PER element reference, and a
/// beachballing target would spend it on every node of a walk.
pub const MESSAGE_TIMEOUT: f32 = 0.1;

/// Wall-clock cap on one whole scan, seconds.
///
/// The node budgets below bound the call COUNT, not the duration, and the two are not the same
/// bound: a target that keeps answering slowly-but-successfully stays under budget forever. The
/// status push holds an in-flight latch across this read, so an unbounded walk freezes the push for
/// every session at once. The worst measured cold scan was 180 ms, so a second is generous.
pub const SCAN_DEADLINE: f64 = 1.0;

/// How deep the toolbar walk may descend before it stops.
///
/// Probed: the chrome sits at depth 4 in Safari and 7 in Chrome. Eight is one past the deeper of
/// the two rather than a round number.
pub const TOOLBAR_MAX_DEPTH: u32 = 8;

/// How many nodes one toolbar walk may visit.
pub const TOOLBAR_NODE_BUDGET: u32 = 800;

/// How deep the menu walk may descend below the menu BAR.
///
/// Five, and the number is the shape of a menu bar rather than a guess: the bar's children are the
/// top-level titles (1), each holds one menu (2), whose children are its items (3), an item that
/// nests holds a submenu (4), whose children are items (5). One level of nesting, for the apps that
/// put history under a submenu. Deeper is a menu tree being searched rather than read, and the
/// toolbar strategy already covers the shells that have one.
pub const MENU_MAX_DEPTH: u32 = 5;

/// How many nodes one menu walk may visit.
///
/// Generous on purpose: a full browser menu bar is a few hundred items and the point of a bound
/// here is not to shorten the walk but to make it finite. What actually stops a slow target is
/// [`SCAN_DEADLINE`] — the Swift this replaced had no node bound on the menu scan at all, and the
/// deadline was already the reason that was safe.
pub const MENU_NODE_BUDGET: u32 = 4_000;

/// The `AXRole` of the page's own content subtree.
///
/// Pruned rather than merely skipped: it is the whole rendered document, it can be enormous, and it
/// can never contain the app's own chrome. Walking into it is how a node budget is spent finding
/// nothing.
pub const WEB_AREA_ROLE: &str = "AXWebArea";

/// The `AXRole` a toolbar history control carries.
pub const BUTTON_ROLE: &str = "AXButton";

/// The `AXIdentifier` of the Back button in the WebKit-family shells.
///
/// Matched exactly, and against the identifier rather than the description: a description is
/// localized, so matching one would make the gate work in English and fail everywhere else.
pub const BACK_IDENTIFIER: &str = "BackButton";

/// The `AXIdentifier` of the Forward button, on the same terms.
pub const FORWARD_IDENTIFIER: &str = "ForwardButton";

/// The `AXMenuItemCmdChar` of the Back item.
pub const BACK_CMD_CHAR: &str = "[";

/// The `AXMenuItemCmdChar` of the Forward item.
pub const FORWARD_CMD_CHAR: &str = "]";

/// The `AXMenuItemCmdModifiers` value meaning "⌘ and nothing else".
///
/// Zero, and the check matters: ⌘⇧[ and ⌘⌥[ are other commands in the same menus, and a match that
/// ignored modifiers would read a tab switch as a history state.
pub const CMD_ONLY_MODIFIERS: i64 = 0;

/// What one node of the toolbar walk turned out to be.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct Visit {
    /// Whether the walk must not descend past this node.
    pub prune: bool,
    /// Which control this node IS, if either.
    pub hit: Option<Direction>,
}

/// Classify one node of the toolbar walk.
///
/// A hit does NOT prune. The pair is two separate nodes, and the second may sit below the first in
/// a shell that groups its history controls, so stopping at a match would find half a pair and
/// report the whole app as unknown.
///
/// `identifier` is a CLOSURE rather than a value, and that is the shape of the perf property this
/// reading depends on. Reading an attribute is a blocking out-of-process round trip, most nodes of
/// a toolbar walk are not buttons, and an eager second read would double the cost of an 800-node
/// walk to learn nothing. Which nodes are worth asking is a policy question, so it is answered
/// here rather than by the caller deciding when to pass a value.
#[must_use]
pub fn toolbar_visit<F: FnOnce() -> Option<String>>(role: Option<&str>, identifier: F) -> Visit {
    if role == Some(WEB_AREA_ROLE) {
        return Visit {
            prune: true,
            hit: None,
        };
    }
    if role != Some(BUTTON_ROLE) {
        return Visit::default();
    }
    let hit = match identifier().as_deref() {
        Some(BACK_IDENTIFIER) => Some(Direction::Back),
        Some(FORWARD_IDENTIFIER) => Some(Direction::Forward),
        _ => None,
    };
    Visit { prune: false, hit }
}

/// Classify one menu item from its key equivalent.
///
/// Both halves must agree — the character AND the modifiers — because either alone names a
/// different command in the same menu.
///
/// `modifiers` is a closure for the reason [`toolbar_visit`]'s `identifier` is, and it is read
/// SECOND on purpose: almost no menu item's key equivalent is `[` or `]`, so testing the character
/// first means the modifier round trip is paid only by the handful that could still match.
#[must_use]
pub fn menu_visit<F: FnOnce() -> Option<i64>>(cmd_char: Option<&str>, modifiers: F) -> Option<Direction> {
    let direction = match cmd_char {
        Some(BACK_CMD_CHAR) => Direction::Back,
        Some(FORWARD_CMD_CHAR) => Direction::Forward,
        _ => return None,
    };
    (modifiers() == Some(CMD_ONLY_MODIFIERS)).then_some(direction)
}

/// A bounded depth-first walk's remaining allowance.
///
/// Depth and node count are two different bounds and both are needed: depth alone lets a wide
/// shallow tree cost thousands of IPC round trips, and a node count alone lets one deep spine run
/// past the chrome into the document.
#[derive(Clone, Copy, Debug)]
pub struct Budget {
    nodes: u32,
    max_depth: u32,
}

impl Default for Budget {
    fn default() -> Self {
        Self::new()
    }
}

impl Budget {
    /// The toolbar walk's allowance.
    #[must_use]
    pub const fn new() -> Self {
        Self {
            nodes: TOOLBAR_NODE_BUDGET,
            max_depth: TOOLBAR_MAX_DEPTH,
        }
    }

    /// An allowance with both bounds named, for a test or a second strategy.
    #[must_use]
    pub const fn with_limits(nodes: u32, max_depth: u32) -> Self {
        Self { nodes, max_depth }
    }

    /// Whether a node at `depth` may be visited at all.
    #[must_use]
    pub const fn may_visit(&self, depth: u32) -> bool {
        depth <= self.max_depth && self.nodes > 0
    }

    /// Charge one node. Saturating, so a caller that spends without asking cannot wrap.
    pub const fn spend(&mut self) {
        self.nodes = self.nodes.saturating_sub(1);
    }

    /// How many nodes are left.
    #[must_use]
    pub const fn remaining(&self) -> u32 {
        self.nodes
    }
}

/// What a caller should do about `pid` on this beat.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Plan {
    /// Read the pair already held. `verify_currency` asks for one extra IPC round trip first — the
    /// app's focused window, compared against the window the pair was scanned from.
    Reuse {
        /// Whether to confirm the pair still belongs to the window that would receive the chord.
        verify_currency: bool,
    },
    /// Walk the tree for a pair.
    Scan,
    /// Answer unknown without touching the target at all.
    Skip,
}

/// Which pid is held, and which one was already searched in vain.
///
/// The empty-scan memory is not an optimisation of a rare case. A browser with no windows open has
/// no pair to find, and the change-poll runs at 4 Hz — so without it, every quarter second buys a
/// full 25 ms-plus walk that is already known to end in nothing. The slow heartbeat retries it, so
/// an app that is merely mid-launch is picked up within about two seconds.
#[derive(Clone, Copy, Debug, Default)]
pub struct Cache {
    held: Option<(i32, Strategy)>,
    empty: Option<i32>,
}

impl Cache {
    /// Nothing held, nothing known empty.
    #[must_use]
    pub const fn new() -> Self {
        Self {
            held: None,
            empty: None,
        }
    }

    /// What to do about `pid` this beat.
    ///
    /// `rescan_unknown` is the slow heartbeat's flag: it lets a pid whose last scan found nothing
    /// be tried again, while the fast poll skips it.
    ///
    /// `verify_currency` is the same beat's permission to spend one more round trip confirming that
    /// a TOOLBAR pair still belongs to the focused window. It is gated because the fetch is live
    /// IPC and a perf audit caught it costing 1–6 ms four times a second for as long as such a
    /// browser stayed frontmost. Between forced beats an intra-app window switch can serve the
    /// old window's flags for up to about two seconds, which is cosmetic: the FIRE path is
    /// ungated, so a stale chip is at worst a chord that does nothing, and a window that CLOSED
    /// rather than merely lost focus fails the ordinary read and rescans on the very next beat.
    ///
    /// A MENU pair is never verified, because it is app-global — Chromium retargets the ⌘[/⌘] items
    /// to whichever window is active — so a currency check on one would be a round trip that can
    /// only answer yes.
    #[must_use]
    pub fn plan(&self, pid: i32, rescan_unknown: bool, verify_currency: bool) -> Plan {
        if let Some((held, strategy)) = self.held
            && held == pid
        {
            return Plan::Reuse {
                verify_currency: verify_currency && strategy == Strategy::Toolbar,
            };
        }
        if self.empty == Some(pid) && !rescan_unknown {
            return Plan::Skip;
        }
        Plan::Scan
    }

    /// Record that `pid` now has a pair, found by `strategy`.
    pub const fn hold(&mut self, pid: i32, strategy: Strategy) {
        self.held = Some((pid, strategy));
        self.empty = None;
    }

    /// Record that a full scan of `pid` found no pair.
    pub const fn found_nothing(&mut self, pid: i32) {
        self.held = None;
        self.empty = Some(pid);
    }

    /// Forget the held pair without claiming its pid is pairless.
    ///
    /// This is the stale-element and moved-focus path, and it deliberately does NOT set the empty
    /// memory: the pair failed, which says nothing about whether a fresh scan would find one, and
    /// recording it as empty would suppress the very rescan that repairs the state.
    pub const fn release(&mut self) {
        self.held = None;
    }

    /// The pid whose pair is held, if any.
    #[must_use]
    pub const fn holding(&self) -> Option<i32> {
        match self.held {
            Some((pid, _)) => Some(pid),
            None => None,
        }
    }
}

/// Fold two `AXEnabled` reads into one answer.
///
/// Both or neither. Half a truth would dark exactly one edge of the chip, and an edge that is dark
/// because a read failed looks identical to one that is dark because the history is empty — so the
/// caller would show a confident wrong answer instead of no answer.
#[must_use]
pub const fn fold(back: Option<bool>, forward: Option<bool>) -> Option<Flags> {
    match (back, forward) {
        (Some(can_go_back), Some(can_go_forward)) => {
            Some(Flags {
                can_go_back,
                can_go_forward,
            })
        },
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::{
        BACK_CMD_CHAR, BACK_IDENTIFIER, BUTTON_ROLE, Budget, Cache, Direction, FORWARD_CMD_CHAR,
        FORWARD_IDENTIFIER, Flags, Plan, Strategy, Visit, WEB_AREA_ROLE, fold, menu_visit, toolbar_visit,
    };

    /// The two identifiers are the whole toolbar reading, and they are matched on a BUTTON. A
    /// non-button carrying the same identifier is some shell's container, not the control.
    #[test]
    fn only_a_button_with_the_right_identifier_is_a_history_control() {
        assert_eq!(
            toolbar_visit(Some(BUTTON_ROLE), || Some(BACK_IDENTIFIER.to_owned())).hit,
            Some(Direction::Back)
        );
        assert_eq!(
            toolbar_visit(Some(BUTTON_ROLE), || Some(FORWARD_IDENTIFIER.to_owned())).hit,
            Some(Direction::Forward)
        );
        assert_eq!(
            toolbar_visit(Some("AXGroup"), || Some(BACK_IDENTIFIER.to_owned())).hit,
            None
        );
        assert_eq!(
            toolbar_visit(Some(BUTTON_ROLE), || Some("ReloadButton".to_owned())).hit,
            None
        );
        assert_eq!(toolbar_visit(Some(BUTTON_ROLE), || None).hit, None);
        assert_eq!(toolbar_visit(None, || None), Visit::default());
    }

    /// The page's own subtree is pruned and nothing else is. A shell whose chrome sat under a web
    /// area would be unreadable, and none does — but a walk that pruned more would be silently
    /// unable to see controls it should.
    #[test]
    fn the_page_subtree_is_pruned_and_nothing_else_is() {
        assert!(toolbar_visit(Some(WEB_AREA_ROLE), || None).prune);
        assert!(
            toolbar_visit(Some(WEB_AREA_ROLE), || Some(BACK_IDENTIFIER.to_owned()))
                .hit
                .is_none()
        );
        for role in ["AXToolbar", "AXGroup", BUTTON_ROLE, "AXWindow"] {
            assert!(!toolbar_visit(Some(role), || None).prune, "{role} was pruned");
        }
    }

    /// A hit must not prune. The pair is two nodes and a shell may nest the second under the first,
    /// so stopping at a match would find half a pair — which the fold then reports as UNKNOWN,
    /// turning a working browser into one the chip never lights for.
    #[test]
    fn finding_one_control_does_not_stop_the_walk_reaching_the_other() {
        assert!(!toolbar_visit(Some(BUTTON_ROLE), || Some(BACK_IDENTIFIER.to_owned())).prune);
        assert!(!toolbar_visit(Some(BUTTON_ROLE), || Some(FORWARD_IDENTIFIER.to_owned())).prune);
    }

    /// ⌘[ and ⌘] only. The same characters under ⌘⇧ or ⌘⌥ are other commands in the same menus, so
    /// the modifier check is what keeps a tab switch from being read as a history state.
    #[test]
    fn a_menu_item_matches_only_on_a_bare_command_key_equivalent() {
        assert_eq!(menu_visit(Some(BACK_CMD_CHAR), || Some(0)), Some(Direction::Back));
        assert_eq!(
            menu_visit(Some(FORWARD_CMD_CHAR), || Some(0)),
            Some(Direction::Forward)
        );
        for modifiers in [1, 2, 4, 8, -1] {
            assert_eq!(menu_visit(Some(BACK_CMD_CHAR), || Some(modifiers)), None);
        }
        assert_eq!(menu_visit(Some(BACK_CMD_CHAR), || None), None);
        assert_eq!(menu_visit(Some("W"), || Some(0)), None);
        assert_eq!(menu_visit(None, || Some(0)), None);
    }

    /// Depth and node count bound different shapes of tree, so both are checked and neither alone
    /// is enough.
    #[test]
    fn both_bounds_stop_a_walk_and_each_stops_a_tree_the_other_cannot() {
        let deep = Budget::with_limits(1_000, 2);
        assert!(deep.may_visit(2));
        assert!(!deep.may_visit(3), "a deep spine ran past its depth bound");

        let mut wide = Budget::with_limits(2, 1_000);
        assert!(wide.may_visit(0));
        wide.spend();
        wide.spend();
        assert!(!wide.may_visit(0), "a wide level ran past its node bound");
    }

    /// Spending past empty saturates rather than wrapping — a wrapped counter would hand a walk
    /// four billion more nodes at exactly the moment it was meant to stop.
    #[test]
    fn a_budget_spent_past_empty_stays_empty() {
        let mut budget = Budget::with_limits(1, 8);
        for _ in 0..100 {
            budget.spend();
        }
        assert_eq!(budget.remaining(), 0);
        assert!(!budget.may_visit(0));
    }

    /// The default allowance is the probed one, and it is deep enough for the deeper of the two
    /// shells that were measured.
    #[test]
    fn the_default_allowance_reaches_past_the_deepest_probed_chrome() {
        let budget = Budget::new();
        assert!(budget.may_visit(7), "Chrome's chrome sits at depth 7");
        assert!(!budget.may_visit(9));
        assert_eq!(budget.remaining(), super::TOOLBAR_NODE_BUDGET);
    }

    /// A held pair is reused; a different pid is not. The pid is the whole identity of a cache
    /// entry, because the elements inside it belong to one process and mean nothing in another.
    #[test]
    fn a_pair_is_reused_only_for_the_process_it_was_scanned_from() {
        let mut cache = Cache::new();
        cache.hold(42, Strategy::Menu);
        assert_eq!(cache.plan(42, false, false), Plan::Reuse {
            verify_currency: false
        });
        assert_eq!(cache.plan(43, false, false), Plan::Scan);
        assert_eq!(cache.holding(), Some(42));
    }

    /// Only a TOOLBAR pair is ever verified, and only on a beat that asked. A menu pair is
    /// app-global, so its currency check could only ever answer yes — one live round trip for a
    /// foregone conclusion.
    #[test]
    fn currency_is_checked_for_the_strategy_whose_state_is_per_window_and_no_other() {
        let mut cache = Cache::new();
        cache.hold(7, Strategy::Toolbar);
        assert_eq!(cache.plan(7, false, true), Plan::Reuse {
            verify_currency: true
        });
        assert_eq!(cache.plan(7, false, false), Plan::Reuse {
            verify_currency: false
        });

        cache.hold(7, Strategy::Menu);
        assert_eq!(cache.plan(7, false, true), Plan::Reuse {
            verify_currency: false
        });
    }

    /// A pid that scanned empty is skipped by the fast poll and retried by the heartbeat. Without
    /// the skip, a browser with no windows costs a full walk four times a second forever.
    #[test]
    fn a_pid_that_scanned_empty_is_skipped_until_the_heartbeat_asks() {
        let mut cache = Cache::new();
        cache.found_nothing(9);
        assert_eq!(cache.plan(9, false, false), Plan::Skip);
        assert_eq!(cache.plan(9, true, false), Plan::Scan);
        assert_eq!(
            cache.plan(10, false, false),
            Plan::Scan,
            "another pid is unaffected"
        );
    }

    /// Releasing a stale pair must NOT record its pid as pairless. Recording it would suppress the
    /// rescan on the very next beat — which is the rescan that repairs the state — and the app
    /// would report unknown until the heartbeat came round.
    #[test]
    fn releasing_a_stale_pair_leaves_the_next_beat_free_to_rescan() {
        let mut cache = Cache::new();
        cache.hold(5, Strategy::Toolbar);
        cache.release();
        assert_eq!(cache.holding(), None);
        assert_eq!(cache.plan(5, false, false), Plan::Scan);
    }

    /// Finding a pair clears an earlier empty verdict for the same pid, so an app that was
    /// mid-launch is not held back by what was true before its window came up.
    #[test]
    fn a_pair_found_after_an_empty_scan_clears_the_empty_verdict() {
        let mut cache = Cache::new();
        cache.found_nothing(11);
        cache.hold(11, Strategy::Toolbar);
        cache.release();
        assert_eq!(cache.plan(11, false, false), Plan::Scan);
    }

    /// Both directions or nothing. One readable half is not half an answer — it is a confident
    /// wrong one, because a dark edge from a failed read is indistinguishable from a dark edge from
    /// an empty history.
    #[test]
    fn one_readable_direction_is_not_half_an_answer() {
        assert_eq!(
            fold(Some(true), Some(false)),
            Some(Flags {
                can_go_back: true,
                can_go_forward: false
            })
        );
        assert_eq!(fold(Some(true), None), None);
        assert_eq!(fold(None, Some(true)), None);
        assert_eq!(fold(None, None), None);
    }
}
