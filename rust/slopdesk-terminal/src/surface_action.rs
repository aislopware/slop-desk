//! The binding-action grammar: the ten spellings the terminal surface answers to.
//!
//! A binding action is a short ASCII string — `scroll_page_lines:-3`, `jump_to_prompt:1`,
//! `search:needle` — handed to the surface as one opaque `String` and executed there. It is the
//! one seam in this app where a `String` beats a typed enum, and the reason is worth stating
//! because the instinct runs the other way: the seam crosses FFI *and* a protocol boundary
//! (`TerminalSurfaceActions`) that four different test doubles conform to. A typed enum would have
//! to be spelled in Swift as well as Rust, and the whole point of this module is that it is
//! spelled once.
//!
//! ## ⚠️ THE GRAMMAR LIVES HERE AND NOWHERE ELSE
//!
//! Every producer calls [`SurfaceAction::spell`] and the single consumer calls
//! [`SurfaceAction::parse`]. Nothing else may write one of these strings — not a `format!` in
//! `slopdesk-workspace`, and above all not a Swift interpolation, which is how six of these
//! spellings used to be born. That mattered because of the failure mode: the executor answers an
//! unrecognised action by doing NOTHING and returning `false`. A typo does not raise; it makes a
//! keystroke quietly stop working, and it does so on exactly the paths (copy mode, block hops)
//! that nobody exercises in a smoke test.
//!
//! `spell` and `parse` are inverses over every variant, and
//! [`tests::every_variant_survives_a_round_trip`] is what keeps them so. Adding a variant without
//! adding it there does not compile — the match is exhaustive on both sides.
//!
//! ## Why the arguments are the widths they are
//!
//! Each numeric payload is as wide as its producer needs and no wider, so a value that could not
//! occur has no spelling. Rows are `u32` (a grid row index, never negative — the scrollback's
//! oldest retained row is 0). Line deltas are `i32` and prompt deltas `i16`, both signed because
//! negative means "towards older scrollback" — a convention this grammar inherited from the
//! terminal it replaced and keeps because every caller already reasons in it.
//!
//! The one float is [`SurfaceAction::ScrollFraction`], and it is a float rather than a page count
//! because "a page" is deliberately not a page: 0.9 leaves a sliver of overlap so a reader keeps a
//! line of context across the jump. It is spelled with Rust's shortest round-tripping `{}`
//! formatting, which is why `parse` accepts whatever `f64::from_str` accepts and rejects
//! non-finite values — `scroll_page_fractional:NaN` would otherwise scroll by a distance that
//! compares equal to nothing.

use core::fmt::Write as _;

/// Which way [`SurfaceAction::AdjustSelection`] moves the selection's free end.
///
/// Four directions, because the shift-arrow keybinds are four keys. The selection's ANCHOR does
/// not move; this walks the head, which is why "up" at the top of the scrollback is a no-op rather
/// than an error.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum SelectionEdge {
    /// Shift-↑ — the head moves one row towards older output.
    Up,
    /// Shift-↓ — the head moves one row towards newer output.
    Down,
    /// Shift-← — the head moves one cell left, wrapping to the previous row's end.
    Left,
    /// Shift-→ — the head moves one cell right, wrapping to the next row's start.
    Right,
}

impl SelectionEdge {
    /// The spelling this direction contributes after the colon.
    #[must_use]
    pub const fn word(self) -> &'static str {
        match self {
            Self::Up => "up",
            Self::Down => "down",
            Self::Left => "left",
            Self::Right => "right",
        }
    }

    /// The direction a spelling names, or `None` for anything else.
    #[must_use]
    pub fn from_word(word: &str) -> Option<Self> {
        match word {
            "up" => Some(Self::Up),
            "down" => Some(Self::Down),
            "left" => Some(Self::Left),
            "right" => Some(Self::Right),
            _ => None,
        }
    }
}

/// One binding action, before it is spelled or after it is parsed.
///
/// Borrowed rather than owned for [`Self::Search`] alone: a needle is a slice of the find bar's own
/// buffer on the way out and of the FFI door's argument on the way in, and neither has any reason
/// to allocate a copy just to be matched against.
///
/// Not `Eq`, because [`Self::ScrollFraction`] holds an `f64`. That is not a float-comparison
/// hazard in practice — the fractions in flight are the literals 0.5 and 0.9 with a sign — but
/// deriving `Eq` over a float is a promise this type cannot keep, so it does not make it.
#[derive(Clone, Copy, PartialEq, Debug)]
pub enum SurfaceAction<'a> {
    /// Arm the surface's own literal, case-insensitive substring search and let it own the
    /// highlight and the scroll from there.
    Search {
        /// The query text, verbatim — matched as a substring, never as a pattern. May be empty,
        /// which clears the highlight without ending the search.
        needle: &'a str,
    },
    /// Step the armed search's cursor, moving both the highlight and the viewport.
    NavigateSearch {
        /// Down the buffer when set, up when clear.
        forward: bool,
    },
    /// End the search, dropping every highlight it painted.
    EndSearch,
    /// Scroll the viewport so a PHYSICAL grid row is at its top — the row-driven find modes'
    /// whole navigation, since the surface's own matcher cannot match what they matched.
    ScrollToRow(u32),
    /// Scroll by a signed number of ROWS. Negative is towards older scrollback.
    ScrollLines(i32),
    /// Scroll by a signed fraction of the viewport's height. Negative is towards older scrollback.
    ScrollFraction(f64),
    /// Scroll to the oldest retained row.
    ScrollToTop,
    /// Scroll to the newest row, which is where output lands.
    ScrollToBottom,
    /// Scroll so the Nth prompt from the viewport top is at the top. Negative counts backwards
    /// into the scrollback; a delta larger than the number of prompts lands on the last one it
    /// found rather than failing.
    JumpToPrompt(i16),
    /// Move the selection's free end one step, leaving the anchor where it is.
    AdjustSelection(SelectionEdge),
}

impl SurfaceAction<'_> {
    /// This action's spelling — the only place any of these strings is written.
    ///
    /// Allocates, and does so unapologetically: the call sites are keystrokes and gestures, not a
    /// render loop, and a borrowed alternative would have to hand back a buffer the caller then
    /// had to keep alive across the FFI hop.
    #[must_use]
    pub fn spell(self) -> String {
        let mut out = String::new();
        // Every `write!` here is infallible — the sink is a `String`, whose `write_str` cannot
        // fail — so the results are discarded rather than unwrapped. That keeps the crate's
        // no-panic promise without a `expect` that could never fire.
        match self {
            Self::Search { needle } => {
                out.push_str("search:");
                out.push_str(needle);
            },
            Self::NavigateSearch { forward: true } => out.push_str("navigate_search:next"),
            Self::NavigateSearch { forward: false } => out.push_str("navigate_search:previous"),
            Self::EndSearch => out.push_str("end_search"),
            Self::ScrollToRow(row) => {
                let _ = write!(out, "scroll_to_row:{row}");
            },
            Self::ScrollLines(delta) => {
                let _ = write!(out, "scroll_page_lines:{delta}");
            },
            Self::ScrollFraction(fraction) => {
                let _ = write!(out, "scroll_page_fractional:{fraction}");
            },
            Self::ScrollToTop => out.push_str("scroll_to_top"),
            Self::ScrollToBottom => out.push_str("scroll_to_bottom"),
            Self::JumpToPrompt(delta) => {
                let _ = write!(out, "jump_to_prompt:{delta}");
            },
            Self::AdjustSelection(edge) => {
                out.push_str("adjust_selection:");
                out.push_str(edge.word());
            },
        }
        out
    }
}

impl<'a> SurfaceAction<'a> {
    /// The action a spelling names, or `None` if this grammar does not contain it.
    ///
    /// `None` is the whole error vocabulary on purpose. The caller's contract is already
    /// "returns `false` when the action did nothing", so an unparseable action and an action that
    /// could not run are the same answer to the same question, and giving them two answers would
    /// only invite a caller to treat one of them as fatal.
    ///
    /// ⚠️ The argument is split at the FIRST colon, never the last: a needle may contain colons
    /// (`search:a: b`) and must survive verbatim. Every other payload is a number or a word, so
    /// first-colon splitting is unambiguous for all of them.
    #[must_use]
    pub fn parse(spelling: &'a str) -> Option<Self> {
        let (verb, argument) = match spelling.split_once(':') {
            Some((verb, argument)) => (verb, Some(argument)),
            None => (spelling, None),
        };
        match (verb, argument) {
            ("search", Some(needle)) => Some(Self::Search { needle }),
            ("navigate_search", Some("next")) => Some(Self::NavigateSearch { forward: true }),
            ("navigate_search", Some("previous")) => Some(Self::NavigateSearch { forward: false }),
            ("end_search", None) => Some(Self::EndSearch),
            ("scroll_to_row", Some(row)) => row.parse().ok().map(Self::ScrollToRow),
            ("scroll_page_lines", Some(delta)) => delta.parse().ok().map(Self::ScrollLines),
            ("scroll_page_fractional", Some(fraction)) => {
                fraction
                    .parse::<f64>()
                    .ok()
                    .filter(|value| value.is_finite())
                    .map(Self::ScrollFraction)
            },
            ("scroll_to_top", None) => Some(Self::ScrollToTop),
            ("scroll_to_bottom", None) => Some(Self::ScrollToBottom),
            ("jump_to_prompt", Some(delta)) => delta.parse().ok().map(Self::JumpToPrompt),
            ("adjust_selection", Some(word)) => SelectionEdge::from_word(word).map(Self::AdjustSelection),
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{SelectionEdge, SurfaceAction};

    /// Every variant, once, with a payload that is not the type's default — a round trip that only
    /// ever saw zeros would pass with a `spell` that dropped its argument.
    fn every_variant() -> Vec<SurfaceAction<'static>> {
        vec![
            SurfaceAction::Search { needle: "docs" },
            SurfaceAction::NavigateSearch { forward: true },
            SurfaceAction::NavigateSearch { forward: false },
            SurfaceAction::EndSearch,
            SurfaceAction::ScrollToRow(42),
            SurfaceAction::ScrollLines(-3),
            SurfaceAction::ScrollFraction(-0.9),
            SurfaceAction::ScrollToTop,
            SurfaceAction::ScrollToBottom,
            SurfaceAction::JumpToPrompt(-2),
            SurfaceAction::AdjustSelection(SelectionEdge::Left),
        ]
    }

    #[test]
    fn every_variant_survives_a_round_trip() {
        for action in every_variant() {
            let spelling = action.spell();
            assert_eq!(
                SurfaceAction::parse(&spelling),
                Some(action),
                "{spelling} did not parse back to what spelled it"
            );
        }
    }

    /// The spellings themselves, pinned. The round trip above proves `spell` and `parse` agree
    /// with EACH OTHER; only this proves they agree with what the surface actually answers to —
    /// a pair of functions can be perfect inverses of a grammar nobody speaks.
    #[test]
    fn the_spellings_are_the_ones_the_surface_answers_to() {
        let cases = [
            (SurfaceAction::Search { needle: "docs" }, "search:docs"),
            (
                SurfaceAction::NavigateSearch { forward: true },
                "navigate_search:next",
            ),
            (
                SurfaceAction::NavigateSearch { forward: false },
                "navigate_search:previous",
            ),
            (SurfaceAction::EndSearch, "end_search"),
            (SurfaceAction::ScrollToRow(0), "scroll_to_row:0"),
            (SurfaceAction::ScrollToRow(42), "scroll_to_row:42"),
            (SurfaceAction::ScrollLines(-3), "scroll_page_lines:-3"),
            (SurfaceAction::ScrollLines(12), "scroll_page_lines:12"),
            (SurfaceAction::ScrollFraction(-0.9), "scroll_page_fractional:-0.9"),
            (SurfaceAction::ScrollFraction(0.9), "scroll_page_fractional:0.9"),
            (SurfaceAction::ScrollFraction(0.5), "scroll_page_fractional:0.5"),
            (SurfaceAction::ScrollToTop, "scroll_to_top"),
            (SurfaceAction::ScrollToBottom, "scroll_to_bottom"),
            (SurfaceAction::JumpToPrompt(-2), "jump_to_prompt:-2"),
            (SurfaceAction::JumpToPrompt(1), "jump_to_prompt:1"),
            (
                SurfaceAction::AdjustSelection(SelectionEdge::Up),
                "adjust_selection:up",
            ),
            (
                SurfaceAction::AdjustSelection(SelectionEdge::Down),
                "adjust_selection:down",
            ),
            (
                SurfaceAction::AdjustSelection(SelectionEdge::Left),
                "adjust_selection:left",
            ),
            (
                SurfaceAction::AdjustSelection(SelectionEdge::Right),
                "adjust_selection:right",
            ),
        ];
        for (action, spelling) in cases {
            assert_eq!(action.spell(), spelling);
            assert_eq!(SurfaceAction::parse(spelling), Some(action));
        }
    }

    /// A needle carries colons, spaces and non-ASCII verbatim — it is the one payload that is text
    /// rather than a number, and the first-colon split exists for it.
    #[test]
    fn a_needle_survives_its_own_punctuation() {
        for needle in ["a: b  c/d", "", "现在", "::", "search:nested"] {
            let action = SurfaceAction::Search { needle };
            assert_eq!(SurfaceAction::parse(&action.spell()), Some(action));
        }
    }

    /// A verb that takes an argument does not answer without one, and a verb that takes none does
    /// not answer with one. Both directions matter: the executor treats `None` as "did nothing",
    /// so a lenient parser would turn a malformed action into a silent no-op that LOOKED handled.
    #[test]
    fn an_arity_mismatch_is_not_an_action() {
        for spelling in [
            "search",
            "scroll_to_row",
            "scroll_page_lines",
            "jump_to_prompt",
            "adjust_selection",
            "scroll_page_fractional",
            "end_search:1",
            "scroll_to_top:1",
            "scroll_to_bottom:0",
        ] {
            assert_eq!(SurfaceAction::parse(spelling), None, "{spelling} parsed");
        }
    }

    /// A payload that is not the number it claims to be is not an action either — including the
    /// three floats that parse fine and then scroll by a distance nothing compares equal to.
    #[test]
    fn a_payload_that_is_not_its_type_is_not_an_action() {
        for spelling in [
            "scroll_to_row:-1",
            "scroll_to_row:x",
            "scroll_page_lines:1.5",
            "jump_to_prompt:70000",
            "adjust_selection:sideways",
            "navigate_search:sideways",
            "scroll_page_fractional:NaN",
            "scroll_page_fractional:inf",
            "scroll_page_fractional:-inf",
        ] {
            assert_eq!(SurfaceAction::parse(spelling), None, "{spelling} parsed");
        }
    }

    #[test]
    fn an_unknown_verb_is_not_an_action() {
        for spelling in ["", ":", "scroll", "quit", "scroll_page_lines_x:1"] {
            assert_eq!(SurfaceAction::parse(spelling), None, "{spelling} parsed");
        }
    }
}
