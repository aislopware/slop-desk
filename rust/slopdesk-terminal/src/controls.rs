//! The multi-state CONTROL knobs: what each stored token means, and which `ghostty` config token it
//! becomes.
//!
//! Seven settings in the Controls pane are not switches — each is a small closed vocabulary that
//! survives a round trip through the preference store as a STRING. Three separable rules hang off
//! each one, and every one of them was Swift:
//!
//! 1. **Repair.** A token read back from disk is untrusted input: an older build wrote it, a hand
//!    edit made it, a newer build's vocabulary is wider than this one's. Every parse here is
//!    validate-then-REPAIR to the documented default — never a trap, never an [`Option`] the caller
//!    can unwrap into one.
//! 2. **The wire token.** Two of the seven persist under slopdesk's own semantic spelling and are
//!    EMITTED under `ghostty`'s, and one of those mappings is INVERTED — see
//!    [`MouseShiftCapture::config_value`], which is the single most misreadable line in the pane.
//! 3. **The projection.** A four-state value read by a two-state control has to project, and the
//!    projection is a rule ([`MouseShiftCapture::extends_selection`]), not a `== .enabled` check.
//!
//! [`crate::config::Controls`] takes every one of these fields PRE-RESOLVED, which is exactly what
//! made the mapping the portable half: the builder already speaks `ghostty`'s config tokens, so
//! what crossed from Swift was the enum→token step and nothing else.
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

    /// The `ghostty` config format's `mouse-shift-capture` token.
    ///
    /// **The mapping is INVERTED, on purpose.** This enum's axis is "⇧ SELECTS TEXT even when the
    /// app captures the mouse"; `ghostty`'s is the opposite — whether ⇧ is CAPTURED INTO the
    /// mouse protocol and sent to the program. From the vendored `Config.zig`: `false` = ⇧ is
    /// not sent and extends the selection (`ghostty`'s own default, overridable by the program
    /// through `XTSHIFTESCAPE`); `true` = ⇧ is sent to the program (overridable); `never` =
    /// `false` and the program CANNOT override; `always` = `true` and the program cannot
    /// override.
    ///
    /// So "⇧ selects" maps to the DON'T-capture tokens and "⇧ to the program" maps to the capture
    /// ones, and the two hard states swap words as well as sense:
    ///
    /// | this enum | means | `ghostty` |
    /// | --- | --- | --- |
    /// | [`Self::Enabled`] | ⇧ extends the selection, soft | `false` |
    /// | [`Self::Disabled`] | ⇧ goes to the program, soft | `true` |
    /// | [`Self::Always`] | ⇧ always selects, hard | `never` |
    /// | [`Self::Never`] | ⇧ never selects, hard | `always` |
    ///
    /// [`Self::Enabled`] landing on `ghostty`'s own default is what makes a factory terminal
    /// HONOUR the upstream behaviour rather than pin it.
    #[must_use]
    pub const fn config_value(self) -> &'static str {
        match self {
            Self::Disabled => "true",
            Self::Enabled => "false",
            Self::Always => "never",
            Self::Never => "always",
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

    /// The `ghostty` `macos-option-as-alt` token. Only the two ENDS are respelled — `off` →
    /// `false` and `both` → `true` — while the two sided values are already `ghostty`'s own
    /// words.
    #[must_use]
    pub const fn config_value(self) -> &'static str {
        match self {
            Self::Off => "false",
            Self::Both => "true",
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
        SchemeDetection, resolved_clipboard_gates,
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

    /// The mapping the module doc calls the most misreadable line in the pane.
    #[test]
    fn the_shift_capture_mapping_is_inverted_end_to_end() {
        assert_eq!(MouseShiftCapture::Enabled.config_value(), "false");
        assert_eq!(MouseShiftCapture::Disabled.config_value(), "true");
        assert_eq!(MouseShiftCapture::Always.config_value(), "never");
        assert_eq!(MouseShiftCapture::Never.config_value(), "always");
        // The two hard states swap words as well as sense: neither emits its own spelling.
        for state in [MouseShiftCapture::Always, MouseShiftCapture::Never] {
            assert_ne!(state.config_value(), state.token(), "{state:?}");
        }
        // The default honours `ghostty`'s own default rather than pinning against it.
        assert_eq!(MouseShiftCapture::default().config_value(), "false");
    }

    /// A stored `always` must read ON, which a bare `== enabled` check would get wrong.
    #[test]
    fn the_four_way_value_projects_onto_the_two_way_switch() {
        assert!(MouseShiftCapture::Always.extends_selection());
        assert!(MouseShiftCapture::Enabled.extends_selection());
        assert!(!MouseShiftCapture::Never.extends_selection());
        assert!(!MouseShiftCapture::Disabled.extends_selection());
    }

    #[test]
    fn option_as_alt_respells_only_its_two_ends() {
        assert_eq!(OptionAsAlt::Off.config_value(), "false");
        assert_eq!(OptionAsAlt::Both.config_value(), "true");
        for sided in [OptionAsAlt::Left, OptionAsAlt::Right] {
            assert_eq!(sided.config_value(), sided.token(), "{sided:?}");
        }
    }

    /// The one vocabulary that needs no second spelling.
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
