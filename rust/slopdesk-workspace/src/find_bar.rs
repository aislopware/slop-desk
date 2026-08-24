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

#[cfg(test)]
mod tests {
    use super::{POINTER, Rung, TOUCH, TogglePillAppearance, counter_text, rung};

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
}
