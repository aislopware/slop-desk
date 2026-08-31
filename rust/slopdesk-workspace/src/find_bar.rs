//! What the in-pane `⌘F` find bar SAYS and how big it is, for both of the halves that draw it.
//!
//! The bar's behaviour already lived below the view; what was still spelled at the call site was
//! everything the user actually reads — the field's placeholder, the four tooltips, the `N of M`
//! counter's three-way rule — plus its measurements, which were chosen by an `#if os(iOS)` INSIDE
//! the view.
//!
//! ## The rungs are named by the INPUT DEVICE, not by the platform
//!
//! `docs/56` §3 names a platform branch in a view file a smell: it says the numbers belong to the
//! platform, when what they belong to is the POINTER. A finger wants a 34pt plate and a 200pt field
//! whether it is on a phone or on an iPad; a mouse wants the chrome ladder's 24 and 130 whether the
//! Mac is drawing `AppKit` or the simulator is drawing `SwiftUI`. So the rungs are asked for BY
//! NAME here, and each renderer picks the one its input device earns.
//!
//! ⚠️ **One number is restated and it is deliberate.** [`POINTER`]'s plate and icon size are the
//! design floor's `Metric.plate` (24) and `Metric.iconSize` (13) written out. They cannot be READ
//! from there: the token floor is a Swift target above this crate, and nothing below a floor may
//! import it. The alternative — leaving the two rungs absent and letting each renderer fall back to
//! its own ladder — is the `#if` again with extra steps, because then the phone's numbers are
//! values and the Mac's are not, and only one of the two is reviewable here.
//!
//! ## The half that is not words
//!
//! The bar also DRIVES the live surface, and that half was spelled in Swift: the binding actions
//! the surface answers to, the three-flag test for whether the surface's own search can express the
//! bar's mode, the branch that decides what a keystroke arms, vi's `n`/`N` against the direction
//! the bar opened in, and where the selection lands after a step or a rescan. None of it needs a
//! view, and every one of those is a rule the phone's bar and the Mac's must not answer
//! differently.
//!
//! The actions themselves are NOT spelled here: [`slopdesk_terminal::surface_action`] owns that
//! grammar, and [`Action::wire`] delegates to it. A second speller is a typo nothing raises on.

use slopdesk_terminal::surface_action::SurfaceAction;

/// The query field's placeholder — the one word the bar shows before anything is typed.
pub const PLACEHOLDER: &str = "Find";

/// The `∧` chevron's tooltip.
pub const PREVIOUS_MATCH_HELP: &str = "Previous match (⇧⌘G)";

/// The `∨` chevron's tooltip.
pub const NEXT_MATCH_HELP: &str = "Next match (⌘G)";

/// The escalation's tooltip — the in-pane find handing over to cross-tab search.
pub const SEARCH_ALL_TABS_HELP: &str = "Search all tabs (⇧⌘F)";

/// The `×` plate's tooltip.
pub const CLOSE_HELP: &str = "Close (Esc)";

/// The counter under the field: `N of M` when a match is selected, a muted verdict when the query
/// matched nothing, and NOTHING at all under an empty field.
///
/// The third branch is the one worth having as a rule rather than as an `if` in a view body: "No
/// results" under an empty field would report a failure nobody asked for — the same distinction
/// [`crate::global_search::empty_state_line`] draws for the cross-tab surface.
///
/// `position` is the search engine's own current/total passed straight through, so the counter can
/// never disagree with it about which match is current.
#[must_use]
pub fn counter_text(position: Option<(u32, u32)>, query: &str) -> Option<String> {
    if let Some((current, total)) = position {
        return Some(format!("{current} of {total}"));
    }
    if query.is_empty() {
        return None;
    }
    Some(String::from("No results"))
}

/// One rung of the find bar's sizing ladder: the square plate every control stands on, the glyph
/// inside it, and the query field's fixed width.
///
/// The field is FIXED rather than flexible on purpose — the bar floats over live terminal output,
/// and a field that grew with the pane would move the counter and the chevrons under the pointer
/// every time the split moved.
#[derive(Clone, Copy, PartialEq, Debug)]
pub struct Rung {
    /// The square hit plate each control (chevron, escalation, close) occupies.
    pub plate: f64,
    /// The glyph drawn inside that plate.
    pub icon_size: f64,
    /// The query field's width.
    pub field_width: f64,
}

/// A MOUSE drives the bar: the chrome ladder's control plate and icon, and a field sized to the
/// compact card `find.png` shows.
///
/// The two smaller numbers restate the design floor's plate and icon metrics — see the module
/// header for why that is deliberate rather than a leak.
pub const POINTER: Rung = Rung {
    plate: 24.0,
    icon_size: 13.0,
    field_width: 130.0,
};

/// A FINGER drives the bar: a plate big enough to hit and a field wide enough to read a query in
/// over a software keyboard. A touch surface is a TARGET before it is a plate.
pub const TOUCH: Rung = Rung {
    plate: 34.0,
    icon_size: 16.0,
    field_width: 200.0,
};

/// The rung an input device earns: `1` for touch, anything else for the pointer.
///
/// The pointer is the default because it is the one a surface that has not said reads correctly on
/// — an oversized plate on a mouse-driven bar is a layout bug, an undersized one on a touch bar is
/// a control nobody can hit.
#[must_use]
pub const fn rung(touch: bool) -> Rung {
    if touch { TOUCH } else { POINTER }
}

/// What an `Aa` / `ab` / `.*` chip LOOKS like, as one verdict over its two inputs.
///
/// ⚠️ It exists because the table was spelled TWICE — once in the `SwiftUI` pill and once in the
/// `AppKit` one, each deriving a plate, a ring and an ink from `is_on` and `hovering`
/// independently. That is one appearance rule in two languages, and the locked invariant it has to
/// keep ("the find bar and the global-search query bar render the pills IDENTICALLY") could not
/// survive it: a hover plate changed on one side reads as correct on both until someone puts the
/// two surfaces side by side.
///
/// The verdict is SEMANTIC, never a colour: each renderer maps the three cases to its own three
/// tokens.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum TogglePillAppearance {
    /// Off, and the pointer is elsewhere: the chip's own resting plate and a hairline. Never a bare
    /// glyph — every idle chip is DELINEATED (the locked rendering).
    Idle,
    /// Off, pointer over it: the hover plate, hairline held.
    Hovering,
    /// On: accent ink on the accent wash, with the accent ring in place of the hairline.
    On,
}

impl TogglePillAppearance {
    /// ON outranks HOVER, because a chip that lost its accent while the pointer sat on it would
    /// read as having been switched off by the hover itself.
    #[must_use]
    pub const fn resolve(is_on: bool, hovering: bool) -> Self {
        if is_on {
            return Self::On;
        }
        if hovering { Self::Hovering } else { Self::Idle }
    }

    /// The discriminant a renderer maps to its own three tokens.
    #[must_use]
    pub const fn code(self) -> u8 {
        match self {
            Self::Idle => 0,
            Self::Hovering => 1,
            Self::On => 2,
        }
    }
}

// MARK: - What the bar asks the live surface to do

/// One thing the find bar asks its terminal surface for, and the string libghostty parses.
///
/// The vocabulary is CLOSED: these five spellings are the whole of what the bar can say. They were
/// built inline at five Swift call sites — a protocol whose grammar lives in string interpolation
/// has no place that can be read to learn it, and the parser on the other end is
/// `ghostty`'s own, not something this side can regenerate. So the colons and the underscores are
/// typed exactly once, here, and pinned letter for letter below.
///
/// The two nav actions are ONE case with a direction rather than two, because every caller has
/// already resolved `forward` through [`nav_forward`]; two cases would only move that branch
/// outward.
#[expect(
    variant_size_differences,
    reason = "a needle is a borrowed str — two pointer-wide words — and a grid row is a u32; the gap is \
              libghostty's, since only one of its five actions takes text"
)]
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Action<'a> {
    /// Arm libghostty's LITERAL in-surface search with a needle — it owns the highlight and the
    /// scroll from there. Only the modes it can express faithfully send this.
    Search {
        /// The query text, verbatim: libghostty matches it as a substring, not as a pattern.
        needle: &'a str,
    },
    /// Step libghostty's own stateful search cursor, which moves both the highlight and the
    /// viewport.
    Navigate {
        /// Down the buffer when set, up when clear.
        forward: bool,
    },
    /// End the in-surface search, dropping every highlight it painted.
    End,
    /// Scroll the viewport to a PHYSICAL grid row — the row-driven modes' whole navigation, since
    /// libghostty cannot match what they matched.
    ScrollToRow(u32),
}

impl<'a> Action<'a> {
    /// The binding-action string `performBindingAction` parses.
    ///
    /// ⚠️ Spelled by [`SurfaceAction::spell`] rather than by a `format!` here, because the grammar
    /// has exactly one home (`slopdesk_terminal::surface_action`) and the executor answers an
    /// unrecognised action by silently doing nothing. A second speller is a typo that costs a
    /// keystroke and raises nothing.
    #[must_use]
    pub fn wire(self) -> String {
        self.action().spell()
    }

    /// This action as the shared grammar's variant.
    #[must_use]
    pub const fn action(self) -> SurfaceAction<'a> {
        match self {
            Self::Search { needle } => SurfaceAction::Search { needle },
            Self::Navigate { forward } => SurfaceAction::NavigateSearch { forward },
            Self::End => SurfaceAction::EndSearch,
            Self::ScrollToRow(row) => SurfaceAction::ScrollToRow(row),
        }
    }

    /// The discriminant a face names instead of a spelling.
    #[must_use]
    pub const fn code(self) -> u8 {
        match self {
            Self::Search { .. } => 0,
            Self::Navigate { .. } => 1,
            Self::End => 2,
            Self::ScrollToRow(_) => 3,
        }
    }
}

/// Whether the bar's current mode CANNOT be expressed faithfully by libghostty's own search, so the
/// bar must drive navigation from its OWN match rows.
///
/// All three flags say the same thing about that matcher: it is a literal, case-INSENSITIVE
/// substring scan with no word-boundary filter. Regex has no engine behind it; whole-word has no
/// filter; and case-sensitive is the one that reads like it should work and does not — arming
/// `search:` there would highlight, and `navigate_search:` would step, case-folded hits the
/// case-sensitive counter says do not exist. Counter, highlight and chevrons would then disagree
/// permanently.
#[must_use]
pub const fn needs_row_driven_nav(regex: bool, whole_word: bool, case_sensitive: bool) -> bool {
    regex || whole_word || case_sensitive
}

/// What a keystroke, a toggle or an open does to the live surface.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Arming {
    /// End the in-surface search and stop: an empty field has nothing to highlight, and a stale
    /// highlight under a cleared query is the bug this arm exists to prevent.
    End,
    /// End it, then scroll to the current match's row — the row-driven modes' whole navigation. The
    /// `end` is not decoration: it clears the highlight a previous literal arming painted.
    EndThenScroll,
    /// Arm libghostty's literal search with the needle; it owns the highlight and the scroll.
    Search,
}

impl Arming {
    /// The empty field outranks the mode — nothing to search is nothing to search either way.
    #[must_use]
    pub const fn resolve(query_empty: bool, row_driven: bool) -> Self {
        if query_empty {
            return Self::End;
        }
        if row_driven {
            Self::EndThenScroll
        } else {
            Self::Search
        }
    }

    /// The discriminant a face maps back to its own three arms.
    #[must_use]
    pub const fn code(self) -> u8 {
        match self {
            Self::End => 0,
            Self::EndThenScroll => 1,
            Self::Search => 2,
        }
    }
}

/// Which way vi's `n` / `N` steps, given the direction the bar OPENED in.
///
/// vim's rule is "`n` repeats the search in its ORIGINAL direction, `N` in the opposite one", so a
/// `?`-opened backward search makes `n` walk UP the buffer and `N` down. `repeat_same_way` is `n`;
/// clear it for `N`. A forward search — ⌘F and `/` — keeps the natural sense on both.
#[must_use]
pub const fn nav_forward(repeat_same_way: bool, search_backward: bool) -> bool {
    repeat_same_way != search_backward
}

/// Where the selection lands after the match list is rebuilt.
///
/// Keep the user near where they were: the same ORDINAL when it is still in range, the last match
/// when the list shrank under it, the first when they had not chosen one, and nothing at all when
/// the query now matches nothing. Typing into a find bar narrows, so the clamp is the common arm,
/// not the exceptional one.
#[must_use]
pub const fn reanchor(previous: Option<usize>, count: usize) -> Option<usize> {
    if count == 0 {
        return None;
    }
    let Some(prev) = previous else {
        return Some(0);
    };
    Some(if prev < count { prev } else { count - 1 })
}

/// Where the selection lands after one step `forward` (down the buffer) or back.
///
/// The wrap is [`crate::list_nav::wrapped_index`], the same ring step the ⌃⇥ pane switcher and the
/// picker's filter pills take. With NOTHING selected there is no index to step FROM, so the landing
/// is named outright — forward into an unvisited list lands on the FIRST match, backward on the
/// LAST, which is where wrapping off either end goes. A ring rule cannot express "start here", and
/// asking it to would mean picking an origin the user never sat on.
#[must_use]
pub const fn step(current: Option<usize>, forward: bool, count: usize) -> Option<usize> {
    if count == 0 {
        return None;
    }
    let Some(cur) = current else {
        return Some(if forward { 0 } else { count - 1 });
    };
    match crate::list_nav::wrapped_index(cur, if forward { 1 } else { -1 }, count) {
        Some(landed) => Some(landed),
        None => Some(cur),
    }
}

#[cfg(test)]
mod tests {
    use super::{
        Action, Arming, POINTER, Rung, TOUCH, TogglePillAppearance, counter_text, nav_forward,
        needs_row_driven_nav, reanchor, rung, step,
    };

    /// The three-way rule, and the branch worth having: a blank field reports nothing.
    #[test]
    fn the_counter_is_silent_under_an_empty_field() {
        assert_eq!(counter_text(Some((3, 12)), "let"), Some(String::from("3 of 12")));
        assert_eq!(counter_text(None, "let"), Some(String::from("No results")));
        assert_eq!(counter_text(None, ""), None);
    }

    /// A selected match outranks the empty field — the engine's answer is the counter's.
    #[test]
    fn a_position_is_printed_whatever_the_field_holds() {
        assert_eq!(counter_text(Some((1, 1)), ""), Some(String::from("1 of 1")));
    }

    /// A finger's targets are larger than a mouse's, on every axis of the rung.
    #[test]
    fn the_touch_rung_is_larger_on_every_axis() {
        const {
            assert!(TOUCH.plate > POINTER.plate);
            assert!(TOUCH.icon_size > POINTER.icon_size);
            assert!(TOUCH.field_width > POINTER.field_width);
        }
    }

    /// The two numbers the module header calls restated, pinned so a drift in the design floor is
    /// caught by a failing test rather than by a screenshot.
    #[test]
    fn the_pointer_rung_restates_the_chrome_ladder() {
        assert_eq!(POINTER, Rung {
            plate: 24.0,
            icon_size: 13.0,
            field_width: 130.0,
        });
        assert_eq!(rung(false), POINTER);
        assert_eq!(rung(true), TOUCH);
    }

    #[test]
    fn on_outranks_hover() {
        assert_eq!(
            TogglePillAppearance::resolve(true, true),
            TogglePillAppearance::On
        );
        assert_eq!(
            TogglePillAppearance::resolve(true, false),
            TogglePillAppearance::On
        );
        assert_eq!(
            TogglePillAppearance::resolve(false, true),
            TogglePillAppearance::Hovering,
        );
        assert_eq!(
            TogglePillAppearance::resolve(false, false),
            TogglePillAppearance::Idle
        );
        for (index, appearance) in [
            TogglePillAppearance::Idle,
            TogglePillAppearance::Hovering,
            TogglePillAppearance::On,
        ]
        .into_iter()
        .enumerate()
        {
            assert_eq!(usize::from(appearance.code()), index);
        }
    }

    /// The five spellings, letter for letter. This is the one table in the module that CANNOT be
    /// re-derived from anything on this side: it is libghostty's own binding grammar, parsed by a
    /// vendored embedder, so a typo here is a control that silently does nothing.
    #[test]
    fn the_five_binding_actions_are_pinned_letter_for_letter() {
        assert_eq!(Action::Search { needle: "docs" }.wire(), "search:docs");
        assert_eq!(Action::Navigate { forward: true }.wire(), "navigate_search:next");
        assert_eq!(
            Action::Navigate { forward: false }.wire(),
            "navigate_search:previous"
        );
        assert_eq!(Action::End.wire(), "end_search");
        assert_eq!(Action::ScrollToRow(0).wire(), "scroll_to_row:0");
        assert_eq!(Action::ScrollToRow(42).wire(), "scroll_to_row:42");
    }

    /// A needle crosses VERBATIM — libghostty matches it as a substring, so a colon or a space in
    /// the query is query text, never grammar.
    #[test]
    fn the_needle_is_not_escaped_or_trimmed() {
        assert_eq!(Action::Search { needle: "a: b  c/d" }.wire(), "search:a: b  c/d");
        assert_eq!(Action::Search { needle: "" }.wire(), "search:");
        assert_eq!(Action::Search { needle: "现在" }.wire(), "search:现在");
    }

    #[test]
    fn each_action_carries_a_distinct_code() {
        let codes = [
            Action::Search { needle: "x" }.code(),
            Action::Navigate { forward: true }.code(),
            Action::End.code(),
            Action::ScrollToRow(3).code(),
        ];
        assert_eq!(codes, [0, 1, 2, 3]);
        // The direction is a FIELD, not a kind — both navigations answer to the one code.
        assert_eq!(
            Action::Navigate { forward: false }.code(),
            Action::Navigate { forward: true }.code()
        );
    }

    /// Each of the three flags alone is enough — the case-sensitive one being the arm that reads
    /// like it should not need to be there.
    #[test]
    fn any_one_of_the_three_flags_takes_the_bar_off_the_literal_path() {
        assert!(!needs_row_driven_nav(false, false, false));
        assert!(needs_row_driven_nav(true, false, false));
        assert!(needs_row_driven_nav(false, true, false));
        assert!(needs_row_driven_nav(false, false, true));
        assert!(needs_row_driven_nav(true, true, true));
    }

    /// An empty field ends the search whatever the mode — a stale highlight under a cleared query
    /// is the thing this arm exists to prevent.
    #[test]
    fn an_empty_query_ends_the_search_in_every_mode() {
        for row_driven in [false, true] {
            assert_eq!(Arming::resolve(true, row_driven), Arming::End);
        }
        assert_eq!(Arming::resolve(false, true), Arming::EndThenScroll);
        assert_eq!(Arming::resolve(false, false), Arming::Search);
        assert_eq!(
            [
                Arming::End.code(),
                Arming::EndThenScroll.code(),
                Arming::Search.code()
            ],
            [0, 1, 2]
        );
    }

    /// vim's rule, both ways round: a `?`-opened search inverts `n` and `N`, a `/`-opened one does
    /// not.
    #[test]
    fn a_backward_search_inverts_n_and_n_shifted() {
        assert!(nav_forward(true, false), "/ then n walks DOWN");
        assert!(!nav_forward(false, false), "/ then N walks UP");
        assert!(!nav_forward(true, true), "? then n walks UP");
        assert!(nav_forward(false, true), "? then N walks DOWN");
    }

    #[test]
    fn a_rescan_keeps_the_ordinal_it_can_and_clamps_the_one_it_cannot() {
        assert_eq!(reanchor(Some(4), 12), Some(4), "still in range — held");
        assert_eq!(reanchor(Some(11), 12), Some(11), "the last slot is in range");
        assert_eq!(reanchor(Some(40), 12), Some(11), "the list shrank under it");
        assert_eq!(reanchor(None, 12), Some(0), "nothing chosen yet — the first");
        assert_eq!(reanchor(Some(4), 0), None, "nothing matches — nothing selected");
        assert_eq!(reanchor(None, 0), None);
    }

    #[test]
    fn a_step_wraps_at_both_ends_and_names_its_own_first_landing() {
        assert_eq!(step(Some(0), true, 3), Some(1));
        assert_eq!(step(Some(2), true, 3), Some(0), "past the last → the first");
        assert_eq!(step(Some(0), false, 3), Some(2), "past the first → the last");
        assert_eq!(
            step(None, true, 3),
            Some(0),
            "⏎ into an unvisited list → the first"
        );
        assert_eq!(step(None, false, 3), Some(2), "⇧⏎ into one → the last");
        assert_eq!(step(Some(0), true, 0), None);
        assert_eq!(step(None, true, 0), None);
        assert_eq!(
            step(Some(9), true, 3),
            Some(9),
            "an index off the ring is held, never wrapped to a slot the user never sat on"
        );
    }

    /// A one-match list is where the row-driven modes re-issue an IDENTICAL `scroll_to_row`, which
    /// the find bar's own header calls expected rather than a stall. Pinned so the ring cannot
    /// start answering `None` there.
    #[test]
    fn a_single_match_steps_to_itself_in_both_directions() {
        assert_eq!(step(Some(0), true, 1), Some(0));
        assert_eq!(step(Some(0), false, 1), Some(0));
    }
}
