//! The multi-state CONTROL knobs: what each stored token means.
//!
//! Seven settings in the Controls pane are not switches — each is a small closed vocabulary that
//! survives a round trip through the preference store as a STRING. Three separable rules hang off
//! each one, and every one of them was Swift:
//!
//! 1. **Repair.** A token read back from disk is untrusted input: an older build wrote it, a hand
//!    edit made it, a newer build's vocabulary is wider than this one's. Every parse here is
//!    validate-then-REPAIR to the documented default — never a trap, never an [`Option`] the caller
//!    can unwrap into one.
//! 2. **The projection.** A four-state value read by a two-state control has to project, and the
//!    projection is a rule ([`MouseShiftCapture::extends_selection`]), not a `== .enabled` check.
//!
//! ## The `ghostty` config spelling is gone
//!
//! Two of the seven used to carry a SECOND token beside the stored one — the word the deleted
//! fork's config text spelled the same setting with, one of them inverted against this enum's own
//! axis. Nothing emits that text any more (see [`crate::config`]), so the transcription had no
//! reader and the inversion was a trap kept for its own sake. What a setting means is now stated
//! once, in the token a user actually types.
//!
//! What is NOT here: the bundle that reads them. Its every field comes from a typed key in the
//! preference store, and a property wrapper whose point is that the platform observes the read does
//! not cross a C boundary.

use crate::link::LinkSchemePolicy;
use crate::link_action::{CmdClick, CmdShiftClick};

/// A clipboard-access decision for the OSC 52 read and write gates.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum ClipboardAccess {
    /// Honour the request silently.
    Allow,
    /// Refuse it silently.
    Deny,
    /// Put the confirmation up. The conservative gate, and the default an unreadable token repairs
    /// to: asking a question is the only answer that is wrong in neither direction.
    #[default]
    Ask,
}

impl ClipboardAccess {
    /// Every gate, in token order.
    pub const ALL: [Self; 3] = [Self::Allow, Self::Deny, Self::Ask];

    /// The gate a stored token names, repairing an unrecognised one to [`ClipboardAccess::Ask`].
    #[must_use]
    pub fn from_token(token: &str) -> Self {
        match token {
            "allow" => Self::Allow,
            "deny" => Self::Deny,
            _ => Self::Ask,
        }
    }

    /// The stored token, which is ALSO the `ghostty` `clipboard-read` / `clipboard-write` value —
    /// this is the one vocabulary of the seven that needs no second spelling.
    #[must_use]
    pub const fn token(self) -> &'static str {
        match self {
            Self::Allow => "allow",
            Self::Deny => "deny",
            Self::Ask => "ask",
        }
    }

    /// What a clipboard READ resolves to WITHOUT a dialog, as the text handed back to the embedder.
    ///
    /// [`ClipboardAccess::Deny`] answers with an EMPTY string rather than with nothing: a
    /// well-formed empty reply completes the request without leaking the clipboard, where a
    /// dropped reply leaves the requesting program waiting. [`ClipboardAccess::Ask`] answers
    /// [`None`] — the surface puts the sheet up and maps the verdict onto the same two answers.
    ///
    /// The paired completion is `confirmed: true` in BOTH allow and deny — a rule carried over from
    /// the deleted libghostty fork, whose surface would re-enter its own read gate and ask again on
    /// a `confirmed: false` completion. `libghostty-vt` drops an OSC 52 READ upstream and never
    /// forwards it at all (`docs/DECISIONS.md`, "Dropped: the OSC-52 clipboard READ gate"), so
    /// this function currently has no caller; the contract is kept in case a read gate is
    /// rebuilt on top of the new engine. A read is not a paste, and the two contracts differed
    /// exactly here.
    #[must_use]
    pub fn silent_read(self, text: &str) -> Option<String> {
        match self {
            Self::Allow => Some(text.to_owned()),
            Self::Deny => Some(String::new()),
            Self::Ask => None,
        }
    }
}

/// What a BARE right click does in the viewport.
///
/// ⌃ with a right click always raises the menu whatever this says; that override is the one piece
/// of right-click behaviour the near side still owns.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum RightClickAction {
    /// Raise the platform context menu.
    #[default]
    ContextMenu,
    /// Copy the selection.
    Copy,
    /// Paste the clipboard.
    Paste,
    /// Copy when there is a selection, otherwise paste.
    CopyOrPaste,
    /// Nothing.
    Ignore,
}

impl RightClickAction {
    /// Every action, in token order.
    pub const ALL: [Self; 5] = [
        Self::ContextMenu,
        Self::Copy,
        Self::Paste,
        Self::CopyOrPaste,
        Self::Ignore,
    ];

    /// The action a stored token names, repairing an unrecognised one to
    /// [`RightClickAction::ContextMenu`].
    #[must_use]
    pub fn from_token(token: &str) -> Self {
        match token {
            "copy" => Self::Copy,
            "paste" => Self::Paste,
            "copy-or-paste" => Self::CopyOrPaste,
            "ignore" => Self::Ignore,
            _ => Self::ContextMenu,
        }
    }

    /// The stored token, which the builder emits verbatim as the `ghostty` config format's
    /// `right-click-action` line.
    ///
    /// That was originally a RACE fix rather than a shortcut: handing the deleted libghostty fork
    /// the action let libghostty perform it end to end, where a near-side dispatch would have
    /// had to re-read whether a selection existed AFTER libghostty had already word-selected
    /// under the cursor, and read the wrong answer. The fork is gone, but the same token is
    /// what `crate::surface::right_click` reads directly now, and it still reads selection state
    /// BEFORE forwarding the click for the identical reason.
    #[must_use]
    pub const fn token(self) -> &'static str {
        match self {
            Self::ContextMenu => "context-menu",
            Self::Copy => "copy",
            Self::Paste => "paste",
            Self::CopyOrPaste => "copy-or-paste",
            Self::Ignore => "ignore",
        }
    }
}

/// Whether ⇧ with a click or a drag makes a native SELECTION even while a program has captured the
/// mouse.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum MouseShiftCapture {
    /// ⇧ goes to the program; no selection. The program may override.
    Disabled,
    /// ⇧ extends the selection. The program may override. The default.
    #[default]
    Enabled,
    /// ⇧ ALWAYS extends the selection; the program cannot override.
    Always,
    /// ⇧ is NEVER consumed for selection; the program cannot override.
    Never,
}

impl MouseShiftCapture {
    /// Every state, in token order.
    pub const ALL: [Self; 4] = [Self::Disabled, Self::Enabled, Self::Always, Self::Never];

    /// The state a stored token names, repairing an unrecognised one to
    /// [`MouseShiftCapture::Enabled`].
    #[must_use]
    pub fn from_token(token: &str) -> Self {
        match token {
            "disabled" => Self::Disabled,
            "always" => Self::Always,
            "never" => Self::Never,
            _ => Self::Enabled,
        }
    }

    /// The stored token — slopdesk's own semantic spelling, kept readable in the preference file.
    #[must_use]
    pub const fn token(self) -> &'static str {
        match self {
            Self::Disabled => "disabled",
            Self::Enabled => "enabled",
            Self::Always => "always",
            Self::Never => "never",
        }
    }

    /// Whether ⇧ EXTENDS THE SELECTION — the ON reading of the two-state "Allow Shift with Mouse
    /// Click" switch the settings pane actually draws.
    ///
    /// The four-way picker is gone but its values persist, so a stored `always` has to project onto
    /// the switch. It reads ON here; against a bare `== enabled` comparison it would have read OFF,
    /// and the switch would have contradicted the behaviour.
    #[must_use]
    pub const fn extends_selection(self) -> bool {
        matches!(self, Self::Enabled | Self::Always)
    }
}

/// How the platform's Option key is treated for terminal input.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum OptionAsAlt {
    /// Option composes accented characters as usual. The default.
    #[default]
    Off,
    /// BOTH Option keys send Alt/Meta, Esc-prefixed.
    Both,
    /// Only the left Option key does; the right still composes.
    Left,
    /// Only the right one does.
    Right,
}

impl OptionAsAlt {
    /// Every state, in token order.
    pub const ALL: [Self; 4] = [Self::Off, Self::Both, Self::Left, Self::Right];

    /// The state a stored token names, repairing an unrecognised one to [`OptionAsAlt::Off`].
    #[must_use]
    pub fn from_token(token: &str) -> Self {
        match token {
            "both" => Self::Both,
            "left" => Self::Left,
            "right" => Self::Right,
            _ => Self::Off,
        }
    }

    /// The stored token — slopdesk's own kebab spelling, so `both` persists as `both` and the
    /// preference file stays readable.
    #[must_use]
    pub const fn token(self) -> &'static str {
        match self {
            Self::Off => "off",
            Self::Both => "both",
            Self::Left => "left",
            Self::Right => "right",
        }
    }
}

/// Which URL schemes are auto-detected and underlined.
///
/// `http`, `https`, `file` and `mailto` are detected whatever this says; only OTHER `scheme://…`
/// forms are governed here.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum SchemeDetection {
    /// Any `scheme://…`.
    #[default]
    All,
    /// The always-on schemes plus the user's own list.
    Custom,
}

impl SchemeDetection {
    /// Both modes, in token order.
    pub const ALL: [Self; 2] = [Self::All, Self::Custom];

    /// The mode a stored token names, repairing an unrecognised one to [`SchemeDetection::All`].
    #[must_use]
    pub fn from_token(token: &str) -> Self {
        match token {
            "custom" => Self::Custom,
            _ => Self::All,
        }
    }

    /// The stored token.
    #[must_use]
    pub const fn token(self) -> &'static str {
        match self {
            Self::All => "all",
            Self::Custom => "custom",
        }
    }

    /// The detector's own policy, given the user's custom list.
    ///
    /// [`SchemeDetection::All`] discards the list rather than merging it: the list is only
    /// consulted in the restrictive mode, and merging it would make the two modes differ by
    /// nothing.
    #[must_use]
    pub fn policy(self, custom: &[String]) -> LinkSchemePolicy {
        match self {
            Self::All => LinkSchemePolicy::All,
            Self::Custom => LinkSchemePolicy::Custom(custom.to_vec()),
        }
    }
}

/// How far past the NEWEST line the viewport may travel, and what it anchors on when it does.
///
/// Every mode but [`ScrollPastLast::Disabled`] names a row and a place to put it, rather than a
/// number of blank rows: "one screenful of overscroll" reads differently on a tall pane and a short
/// one, where "the last line with content sits at the top" reads the same on both. The anchor is
/// resolved against the laid-out content in `slopdesk_termrender::layout::scroll_bounds` — the
/// crate that has the rects; this enum is only the vocabulary and the projection.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum ScrollPastLast {
    /// Clamp at the bottom of the content, which is where every terminal stops by default.
    #[default]
    Disabled,
    /// The bottom-most row holding text ends up at the top of the viewport.
    LastLineWithContent,
    /// That same row ends up centred.
    LastLineInMiddle,
    /// The CURSOR's row ends up at the top, even when it is blank — which is the difference from
    /// [`ScrollPastLast::LastLineWithContent`], and the whole reason both exist: a shell that
    /// prints a trailing blank line puts the two anchors on different rows.
    CursorLine,
}

impl ScrollPastLast {
    /// Every mode, in token order.
    pub const ALL: [Self; 4] = [
        Self::Disabled,
        Self::LastLineWithContent,
        Self::LastLineInMiddle,
        Self::CursorLine,
    ];

    /// The mode a stored token names, repairing an unrecognised one to
    /// [`ScrollPastLast::Disabled`].
    #[must_use]
    pub fn from_token(token: &str) -> Self {
        match token {
            "last-line-with-content" => Self::LastLineWithContent,
            "last-line-in-middle" => Self::LastLineInMiddle,
            "cursor-line" => Self::CursorLine,
            _ => Self::Disabled,
        }
    }

    /// The stored token.
    #[must_use]
    pub const fn token(self) -> &'static str {
        match self {
            Self::Disabled => "disabled",
            Self::LastLineWithContent => "last-line-with-content",
            Self::LastLineInMiddle => "last-line-in-middle",
            Self::CursorLine => "cursor-line",
        }
    }

    /// The mode at the OTHER end that mirrors this one, for [`ScrollPastFirst::SameAsLast`].
    ///
    /// [`ScrollPastLast::CursorLine`] mirrors onto
    /// [`ScrollPastFirst::FirstLineWithContent`] because there is no cursor at the top of the
    /// scrollback to anchor on — the oldest retained row is the only thing up there, and it is by
    /// definition a row with content.
    #[must_use]
    pub const fn mirrored(self) -> ScrollPastFirst {
        match self {
            Self::Disabled => ScrollPastFirst::Disabled,
            Self::LastLineInMiddle => ScrollPastFirst::FirstLineInMiddle,
            Self::LastLineWithContent | Self::CursorLine => ScrollPastFirst::FirstLineWithContent,
        }
    }
}

/// How far past the OLDEST retained line the viewport may travel.
///
/// The mirror of [`ScrollPastLast`], with one extra stop: most people want the two ends to behave
/// alike, and [`ScrollPastFirst::SameAsLast`] lets them say so once rather than keep two knobs in
/// step by hand.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum ScrollPastFirst {
    /// Clamp at the top of the scrollback.
    #[default]
    Disabled,
    /// Whatever [`ScrollPastLast`] says, [`ScrollPastLast::mirrored`] onto this end.
    SameAsLast,
    /// The oldest retained row ends up at the BOTTOM of the viewport.
    FirstLineWithContent,
    /// That same row ends up centred.
    FirstLineInMiddle,
}

impl ScrollPastFirst {
    /// Every mode, in token order.
    pub const ALL: [Self; 4] = [
        Self::Disabled,
        Self::SameAsLast,
        Self::FirstLineWithContent,
        Self::FirstLineInMiddle,
    ];

    /// The mode a stored token names, repairing an unrecognised one to
    /// [`ScrollPastFirst::Disabled`].
    #[must_use]
    pub fn from_token(token: &str) -> Self {
        match token {
            "same-as-last" => Self::SameAsLast,
            "first-line-with-content" => Self::FirstLineWithContent,
            "first-line-in-middle" => Self::FirstLineInMiddle,
            _ => Self::Disabled,
        }
    }

    /// The stored token.
    #[must_use]
    pub const fn token(self) -> &'static str {
        match self {
            Self::Disabled => "disabled",
            Self::SameAsLast => "same-as-last",
            Self::FirstLineWithContent => "first-line-with-content",
            Self::FirstLineInMiddle => "first-line-in-middle",
        }
    }

    /// This mode with [`ScrollPastFirst::SameAsLast`] already resolved against `last`.
    ///
    /// Resolving here rather than at the two call sites is what keeps the alias from being a case
    /// every reader of this enum has to remember: past this call there are three stops, not four.
    #[must_use]
    pub const fn resolved(self, last: ScrollPastLast) -> Self {
        match self {
            Self::SameAsLast => last.mirrored(),
            other => other,
        }
    }
}

/// The three scroll knobs that travel together: both overscroll ends, and whether a gesture is
/// allowed to rest between two rows.
///
/// One value rather than three arguments because no caller wants a subset — the bounds need both
/// ends, and the settle needs the bounds plus `smooth`. [`Overscroll::default`] is today's
/// behaviour exactly: clamp at both ends, pixel-smooth in the hand.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Overscroll {
    /// How far past the newest line the viewport may travel.
    pub past_last: ScrollPastLast,
    /// How far past the oldest retained line it may travel.
    pub past_first: ScrollPastFirst,
    /// Whether a scroll may rest between two rows while the gesture is live. Off quantises every
    /// step; on quantises only once the gesture and its momentum are over, so the glyphs settle
    /// pixel-aligned either way and the difference is purely kinetic.
    pub smooth: bool,
}

impl Default for Overscroll {
    fn default() -> Self {
        Self {
            past_last: ScrollPastLast::Disabled,
            past_first: ScrollPastFirst::Disabled,
            smooth: true,
        }
    }
}

/// Where a pointer scroll is in its life, which is what decides when a row snap is owed.
///
/// The snap waits for MOMENTUM to finish rather than for the fingers to lift: a trackpad fling
/// keeps delivering deltas after the gesture ends, and snapping at the lift would fight every one
/// of them.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum ScrollPhase {
    /// A discrete wheel notch, or any source that reports no phase at all. Settles immediately —
    /// there is no gesture to wait for.
    #[default]
    Discrete,
    /// The fingers are down, or the fling is still throwing deltas.
    Live,
    /// The gesture and its momentum are both over.
    Ended,
}

impl ScrollPhase {
    /// Every phase, in code order — the order the C door's `uint8_t` counts in.
    pub const ALL: [Self; 3] = [Self::Discrete, Self::Live, Self::Ended];

    /// Whether a scroll ending in this phase owes a snap to the nearest row, under `smooth`.
    ///
    /// With smooth scrolling OFF every step snaps, which is what makes the motion read as whole-row
    /// jumping; with it ON only the last one does.
    #[must_use]
    pub const fn settles(self, smooth: bool) -> bool {
        !smooth || !matches!(self, Self::Live)
    }
}

/// The stored spelling of the two link-click settings, whose BEHAVIOUR enums already live in
/// [`crate::link_action`]. The tokens hang off them here so the vocabulary that hits disk sits with
/// the other six, and so a repair reads the same as every other repair in the pane.
impl CmdClick {
    /// Every action, in token order.
    pub const ALL: [Self; 3] = [Self::Open, Self::Copy, Self::Nothing];

    /// The action a stored token names, repairing an unrecognised one to [`CmdClick::Open`].
    #[must_use]
    pub fn from_token(token: &str) -> Self {
        match token {
            "copy" => Self::Copy,
            "nothing" => Self::Nothing,
            _ => Self::Open,
        }
    }

    /// The stored token.
    #[must_use]
    pub const fn token(self) -> &'static str {
        match self {
            Self::Open => "open",
            Self::Copy => "copy",
            Self::Nothing => "nothing",
        }
    }
}

impl CmdShiftClick {
    /// Both actions, in token order.
    pub const ALL: [Self; 2] = [Self::RevealFinder, Self::OpenSystemDefault];

    /// The action a stored token names, repairing an unrecognised one to
    /// [`CmdShiftClick::RevealFinder`].
    #[must_use]
    pub fn from_token(token: &str) -> Self {
        match token {
            "open-system-default" => Self::OpenSystemDefault,
            _ => Self::RevealFinder,
        }
    }

    /// The stored token.
    #[must_use]
    pub const fn token(self) -> &'static str {
        match self {
            Self::RevealFinder => "reveal-finder",
            Self::OpenSystemDefault => "open-system-default",
        }
    }
}

/// Whether the OSC 52 path is open at all — the "Clipboard — Shell Controlled" master switch,
/// resolved AHEAD of the per-direction gate.
///
/// With the switch off both directions read [`ClipboardAccess::Deny`], so the builder emits
/// `clipboard-read = deny` and `clipboard-write = deny` and no remote OSC 52 ever reaches the gate.
/// One function rather than a ternary at each of the two read sites, because a master switch
/// honoured in one direction and not the other is the failure this shape rules out.
#[must_use]
pub const fn resolved_clipboard_gates(
    shell_controlled: bool,
    read: ClipboardAccess,
    write: ClipboardAccess,
) -> (ClipboardAccess, ClipboardAccess) {
    if shell_controlled {
        (read, write)
    } else {
        (ClipboardAccess::Deny, ClipboardAccess::Deny)
    }
}

#[cfg(test)]
mod tests {
    use super::{
        ClipboardAccess, CmdClick, CmdShiftClick, MouseShiftCapture, OptionAsAlt, RightClickAction,
        SchemeDetection, ScrollPastFirst, ScrollPastLast, ScrollPhase, resolved_clipboard_gates,
    };
    use crate::link::LinkSchemePolicy;

    /// Round-tripping is the whole persistence contract, and no two cases may share a token.
    #[test]
    fn every_vocabulary_round_trips_and_no_token_is_spelled_twice() {
        macro_rules! round_trip {
            ($ty:ty) => {{
                let mut tokens: Vec<&str> = <$ty>::ALL.iter().map(|case| case.token()).collect();
                for case in <$ty>::ALL {
                    assert_eq!(<$ty>::from_token(case.token()), case, "{case:?}");
                    assert!(!case.token().is_empty());
                }
                let count = tokens.len();
                tokens.sort_unstable();
                tokens.dedup();
                assert_eq!(
                    tokens.len(),
                    count,
                    concat!(stringify!($ty), " spells a token twice")
                );
            }};
        }
        round_trip!(ClipboardAccess);
        round_trip!(RightClickAction);
        round_trip!(MouseShiftCapture);
        round_trip!(OptionAsAlt);
        round_trip!(SchemeDetection);
        round_trip!(CmdClick);
        round_trip!(CmdShiftClick);
        round_trip!(ScrollPastLast);
        round_trip!(ScrollPastFirst);
    }

    /// The alias is resolved ONCE, so every reader past that call sees three stops and not four.
    #[test]
    fn same_as_last_resolves_to_the_other_end_and_never_to_itself() {
        for last in ScrollPastLast::ALL {
            let resolved = ScrollPastFirst::SameAsLast.resolved(last);
            assert_eq!(resolved, last.mirrored(), "{last:?}");
            assert_ne!(resolved, ScrollPastFirst::SameAsLast, "{last:?}");
        }
        // Every other stop is its own answer, whatever the far end says.
        for first in [
            ScrollPastFirst::Disabled,
            ScrollPastFirst::FirstLineWithContent,
            ScrollPastFirst::FirstLineInMiddle,
        ] {
            assert_eq!(first.resolved(ScrollPastLast::CursorLine), first);
        }
    }

    /// Off means "snap every step", not "never snap" — the glyphs settle row-aligned either way.
    #[test]
    fn a_live_step_settles_only_with_smooth_scrolling_off() {
        assert!(!ScrollPhase::Live.settles(true));
        assert!(ScrollPhase::Live.settles(false));
        for phase in [ScrollPhase::Discrete, ScrollPhase::Ended] {
            assert!(phase.settles(true), "{phase:?}");
            assert!(phase.settles(false), "{phase:?}");
        }
    }

    /// Untrusted input never traps and never lands somewhere permissive by accident.
    #[test]
    fn a_hostile_token_repairs_to_the_documented_default() {
        for hostile in ["", "ALLOW", " allow", "allow\0", "\u{1f600}", "context menu"] {
            assert_eq!(
                ClipboardAccess::from_token(hostile),
                ClipboardAccess::Ask,
                "{hostile:?}"
            );
            assert_eq!(
                RightClickAction::from_token(hostile),
                RightClickAction::ContextMenu,
                "{hostile:?}",
            );
            assert_eq!(
                MouseShiftCapture::from_token(hostile),
                MouseShiftCapture::Enabled,
                "{hostile:?}",
            );
            assert_eq!(OptionAsAlt::from_token(hostile), OptionAsAlt::Off, "{hostile:?}");
            assert_eq!(
                SchemeDetection::from_token(hostile),
                SchemeDetection::All,
                "{hostile:?}"
            );
            assert_eq!(CmdClick::from_token(hostile), CmdClick::Open, "{hostile:?}");
            assert_eq!(
                CmdShiftClick::from_token(hostile),
                CmdShiftClick::RevealFinder,
                "{hostile:?}",
            );
        }
        // The repair target is the type's own default, so the two cannot drift apart.
        assert_eq!(ClipboardAccess::from_token("?"), ClipboardAccess::default());
        assert_eq!(RightClickAction::from_token("?"), RightClickAction::default());
        assert_eq!(MouseShiftCapture::from_token("?"), MouseShiftCapture::default());
        assert_eq!(OptionAsAlt::from_token("?"), OptionAsAlt::default());
        assert_eq!(SchemeDetection::from_token("?"), SchemeDetection::default());
        assert_eq!(CmdClick::from_token("?"), CmdClick::default());
        assert_eq!(CmdShiftClick::from_token("?"), CmdShiftClick::default());
    }

    /// A deny answers, rather than leaving the requesting program waiting.
    #[test]
    fn a_denied_read_completes_with_an_empty_string() {
        assert_eq!(
            ClipboardAccess::Allow.silent_read("secret").as_deref(),
            Some("secret")
        );
        assert_eq!(ClipboardAccess::Deny.silent_read("secret").as_deref(), Some(""));
        assert_eq!(ClipboardAccess::Ask.silent_read("secret"), None);
    }

    /// A stored `always` must read ON, which a bare `== enabled` check would get wrong.
    #[test]
    fn the_four_way_value_projects_onto_the_two_way_switch() {
        assert!(MouseShiftCapture::Always.extends_selection());
        assert!(MouseShiftCapture::Enabled.extends_selection());
        assert!(!MouseShiftCapture::Never.extends_selection());
        assert!(!MouseShiftCapture::Disabled.extends_selection());
    }

    /// Every gate persists under a word a user can read back.
    #[test]
    fn the_clipboard_gate_persists_under_libghosttys_own_words() {
        for gate in ClipboardAccess::ALL {
            assert!(matches!(gate.token(), "allow" | "deny" | "ask"));
        }
    }

    #[test]
    fn the_custom_list_is_consulted_only_in_the_restrictive_mode() {
        let custom = vec!["ssh".to_owned()];
        assert_eq!(SchemeDetection::All.policy(&custom), LinkSchemePolicy::All);
        assert_eq!(
            SchemeDetection::Custom.policy(&custom),
            LinkSchemePolicy::Custom(vec!["ssh".to_owned()]),
        );
        assert_eq!(
            SchemeDetection::Custom.policy(&[]),
            LinkSchemePolicy::Custom(Vec::new()),
        );
    }

    /// A master switch honoured in one direction and not the other is what one function rules out.
    #[test]
    fn the_master_switch_closes_both_directions_together() {
        let (read, write) = resolved_clipboard_gates(false, ClipboardAccess::Allow, ClipboardAccess::Allow);
        assert_eq!(read, ClipboardAccess::Deny);
        assert_eq!(write, ClipboardAccess::Deny);
        let (read, write) = resolved_clipboard_gates(true, ClipboardAccess::Ask, ClipboardAccess::Allow);
        assert_eq!(read, ClipboardAccess::Ask);
        assert_eq!(write, ClipboardAccess::Allow);
    }
}
